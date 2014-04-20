require 'dmtest/config'
require 'dmtest/git'
require 'dmtest/log'
require 'dmtest/utils'
require 'dmtest/fs'
require 'dmtest/tags'
require 'dmtest/thinp-test'
require 'dmtest/cache-status'
require 'dmtest/pattern_stomper'
require 'dmtest/disk-units'
require 'dmtest/test-utils'
require 'dmtest/tests/cache/fio_subvolume_scenario'

require 'dmtest/tests/writeboost/status'
require 'dmtest/tests/writeboost/stack'

require 'rspec/expectations'
require 'pp'

#----------------------------------------------------------------

module WriteboostTests
  include GitExtract
  include Tags
  include Utils
  include DiskUnits
  include FioSubVolumeScenario
  extend TestUtils

  attr_accessor :stack_maker

  RUBY = 'ruby-2.1.1.tar.gz'
  RUBY_LOCATION = "http://cache.ruby-lang.org/pub/ruby/2.1/ruby-2.1.1.tar.gz"

  def grab_ruby
    unless File.exist?(RUBY)
      STDERR.puts "grabbing ruby archive from web"
      system("curl #{RUBY_LOCATION} -o #{RUBY}")
    end
  end

  def build_and_test_ruby
    ProcessControl.run("./configure")
    ProcessControl.run("make -j")

    # page caches are dropped before make test
    ProcessControl.run("echo 3 > /proc/sys/vm/drop_caches")
    ProcessControl.run("make test")
  end

  #--------------------------------

  def test_fio_sub_volume
    s = @stack_maker.new(@dm, @data_dev, @metadata_dev);
    s.activate(true) do
      s.cleanup_cache
      wait = lambda {sleep(5)}
      fio_sub_volume_scenario(s.wb, &wait)
    end
  end

  def test_fio_cache
    s = @stack_maker.new(@dm, @data_dev, @metadata_dev);
    s.activate(true) do
      s.cleanup_cache
      do_fio(s.wb, :ext4)
    end
  end

  def test_fio_database_funtime
    s = @stack_maker.new(@dm, @data_dev, @metadata_dev);
    s.activate(true) do
      s.cleanup_cache
      do_fio(s.wb, :ext4,
             :outfile => AP("fio_writeboost.out"),
             :cfgfile => LP("tests/cache/database-funtime.fio"))
    end
  end

  # really a compound test
  def test_compile_ruby
    grab_ruby

    s = @stack_maker.new(@dm, @data_dev, @metadata_dev);
    s.activate_support_devs() do
      s.cleanup_cache

      ruby = "ruby-2.1.1"
      mount_dir = "./ruby_mount_1"

      # for testing segment size order < 10
      # to dig up codes that depend on the order is 10
      sso = 9

      # (1) first extracts the archive in the directory
      # no migration - all dirty data is on the cache device
      no_migrate_args = {
        :segment_size_order => sso,
        :enable_migration_modulator => 0,
        :allow_migrate => 0
      }
      s.table_extra_args = no_migrate_args
      s.activate_top_level(true) do
        fs = FS::file_system(:xfs, s.wb)
        fs.format
        fs.with_mount(mount_dir) do
          pn = RUBY
          ProcessControl.run("cp #{pn} #{mount_dir}")
          Dir.chdir(mount_dir) do
            ProcessControl.run("tar xvfz #{ruby}.tar.gz")
          end
        end
      end

      yes_migrate_args = {
        :segment_size_order => sso,
        :enable_migration_modulator => 1,
        :allow_migrate => 0
      }
      s.table_extra_args = yes_migrate_args
      # (2) replays the log on the cache device
      # if the data corrupts, Ruby can't compile
      # or fs corrupts.
      s.activate_top_level(true) do
        fs = FS::file_system(:xfs, s.wb)

        # (3) drop all the dirty caches
        # to see migration works
        s.wb.message(0, "drop_caches")
        fs.with_mount(mount_dir) do
          Dir.chdir("#{mount_dir}/#{ruby}") do
            build_and_test_ruby
          end
        end
      end
    end
  end

  # Reading from RAM buffer is really an unlikely path
  # in real-world workload.
  def test_rambuf_read_fullsize

    # Cache is bigger than backing.
    # So, no overwrite on cache device occurs.
    # Overwrite may writes back caches on the RAM buffer
    # which we attempt to hit on read.
    opts = {
      :backing_sz => meg(16),
      :cache_sz => meg(32),
    }

    s = @stack_maker.new(@dm, @data_dev, @metadata_dev, opts)
    s.activate_support_devs() do
      s.cleanup_cache
      args = {
        :segment_size_order => 10,
        :enable_migration_modulator => 0,
        :allow_migrate => 0,
      }
      s.table_extra_args = args

      s.activate_top_level(true) do
        st1 = WriteboostStatus.from_raw_status(s.wb.status)
        ps = PatternStomper.new(s.wb.path, k(31), :needs_zero => true)
        ps.stamp(20)
        ps.verify(0, 1)
        st2 = WriteboostStatus.from_raw_status(s.wb.status)
        st2.stat(0, 1, 1, 1).should > st1.stat(0, 1, 1, 1)
      end
    end
  end

  def test_device_failure
    # Making the cache device size smaller to shorten the
    # execution time and repeat tests
    opts = {
      :cache_sz => meg(16)
    }
    s = @stack_maker.new(@dm, @data_dev, @metadata_dev, opts);
    s.activate_support_devs() do
      s.cleanup_cache

      def backing_table_failable(s)
        up = rand(1..3)
        down = 1
        DM::Table.new(DM::FlakeyTarget.new(dev_size(s.backing_dev), s.slow_dev_name, 0, up, down))
      end

      def cache_table_failable(s)
        up = rand(3..10)
        down = 1
        offset = 0 # TODO parse linear table
        DM::Table.new(DM::FlakeyTarget.new(dev_size(s.cache_dev), s.fast_dev_name, offset, up, down))
      end

      def wrap_backing_dev(s, new_table)
        s.backing_dev.pause do
          s.backing_dev.load(new_table)
        end
      end

      def wrap_cache_dev(s, new_table)
        s.cache_dev.pause do
          s.cache_dev.load(new_table)
        end
      end

      backing_table_old = s.backing_dev.table
      cache_table_old = s.cache_dev.table

      mount_dir = "./mnt_wb"

      ProcessControl.run("dmesg -C")
      n = 5 # TODO
      n.times do |i|
        # Activate wb device and fails suddenly
        # and then see if no corruption, either filesystem or compilation, occurs.
        s.activate_top_level(true) do
          fs = FS::file_system(:xfs, s.wb)
          fs.format if i == 0

          release = lambda {
            p "c"
            # We need to unwrap the flakey shell
            # otherwise xfs_repair fails in case of
            # failing metadata I/O in the compilation above.
            # p "d"
            p backing_table_old
            # s.backing_dev.load(backing_table_old)
            wrap_backing_dev s, backing_table_old
            p cache_table_old
            # s.cache_dev.load(cache_table_old)
            wrap_cache_dev s, cache_table_old
            p "e"
            p s.backing_dev.table
            p s.cache_dev.table

            fs.umount
          }

          fs.with_mount(mount_dir, {}, release) do
          # fs.with_mount(mount_dir) do
            p s.backing_dev.table
            p s.cache_dev.table

            if i % 2 == 0
              wrap_backing_dev s, backing_table_failable(s)
            else
              wrap_cache_dev s, cache_table_failable(s)
            end

            p "a"
            Dir.chdir(mount_dir) do
              p "b"
              begin
                command = "fio -name=test -size=128MB -direct=1 -rw=randrw -runtime=30 -numjobs=4 -bs=4k"
                ProcessControl.run(command)
              rescue  
              end
            end
          end
        end
      end
    end
  end
end

class WriteboostTestsType0 < ThinpTestCase
  include WriteboostTests

  def setup
    super
    @stack_maker = WriteboostStackType0
  end
end

class WriteboostTestsType1 < ThinpTestCase
  include WriteboostTests

  def setup
    super
    @stack_maker = WriteboostStackType1
  end
end

#----------------------------------------------------------------
