require 'dmtest/git'
require 'dmtest/log'
require 'dmtest/utils'
require 'dmtest/fs'
require 'dmtest/tags'
require 'dmtest/thinp-test'
require 'dmtest/cache-status'
require 'dmtest/disk-units'
require 'dmtest/test-utils'
require 'dmtest/tvm.rb'
require 'dmtest/cache_stack'
require 'dmtest/cache_policy'

#----------------------------------------------------------------

class BurstyWriteTests < ThinpTestCase
  include GitExtract
  include Tags
  include Utils
  include DiskUnits
  extend TestUtils

  POLICY_NAMES = %w(mq smq)
  MOUNT_DIR = './smallfile-mount'

  def run_smallfile
    nr_threads = 4
    nr_files = 10000
    op = 'create'

    ProcessControl.run("python ~/smallfile/smallfile_cli.py --top #{MOUNT_DIR} --fsync Y --file-size-distribution exponential --hash-into-dirs Y --files-per-dir 30 --dirs-per-dir 5 --threads #{nr_threads} --file-size 64 --operation #{op} --files #{nr_files}")
  end

  def do_smallfile(dev)
    fs = FS::file_system(:xfs, dev)
    fs.format
    fs.with_mount(MOUNT_DIR) do
      run_smallfile
    end
  end

  def test_smallfile_linear
    with_standard_linear(:data_size => gig(4)) do |linear|
      do_smallfile(linear)
    end
  end

  def smallfile_cache(policy)
    stack = CacheStack.new(@dm, @metadata_dev, @data_dev,
                           :data_size => gig(4),
                           :cache_size => meg(1024),
                           :policy => Policy.new(policy, :migration_threshold => 1024));
    stack.activate do |stack|
      do_smallfile(stack.cache)
      pp CacheStatus.new(stack.cache)
    end
  end

  define_tests_across(:smallfile_cache, POLICY_NAMES)
end

#----------------------------------------------------------------
