require 'dmtest/utils'
require 'dmtest/ensure_elapsed'
require 'dmtest/thinp-test'
require 'dmtest/disk-units'
require 'dmtest/test-utils'

#----------------------------------------------------------------

module DM
  class WriteboostTarget < Target
    def initialize(sector_count, args)
      super('writeboost', sector_count, *args)
    end
    # writeboost doesn't need to implement post_remove_check
  end
end

#----------------------------------------------------------------

# template class for stacks
class WriteboostStack
  include EnsureElapsed
  include DiskUnits
  include ThinpTestMixin
  include Utils

  attr_accessor :backing_dev,
                :cache_dev,
                :wb, # :: DMDev
                :opts, # :: {}
                :table_extra_args # :: {}

  def initialize(dm, slow_dev_name, fast_dev_name, opts = {})
    @dm = dm
    @fast_dev_name = fast_dev_name
    @slow_dev_name = slow_dev_name

    @backing_dev = nil
    @cache_dev = nil

    @opts = opts
    @table_extra_args = {}

    @slow_tvm = TinyVolumeManager::VM.new
    @slow_tvm.add_allocation_volume(slow_dev_name)
    @slow_tvm.add_volume(linear_vol('backing_dev', backing_sz))

    @fast_tvm = TinyVolumeManager::VM.new
    @fast_tvm.add_allocation_volume(fast_dev_name)
    @fast_tvm.add_volume(linear_vol('cache_dev', cache_sz))
  end

  def backing_sz
    @opts.fetch(:backing_sz, dev_size(@slow_dev_name))
  end

  def cache_sz
    @opts.fetch(:cache_sz, gig(1))
  end

  def cleanup_cache
    # FIXME
    # @cache_dev.discard(0, dev_size(@cache_dev.path))
    wipe_device(@cache_dev, 1)
  end

  def activate_support_devs(&block)
    with_devs(@slow_tvm.table('backing_dev'),
              @fast_tvm.table('cache_dev')
             ) do |backing_dev, cache_dev|

      @backing_dev = backing_dev
      @cache_dev = cache_dev
      ensure_elapsed_time(1, self, &block)
    end
  end

  # Calling this flushes the current RAM buffer
  def cleanup_forcibly
    @wb.suspend
    @wb.resume
  end

  def activate_top_level(force, &block)
    with_dev(table) do |wb|
      @wb = wb
      ensure_elapsed_time(1, self, &block)
      cleanup_forcibly if force
    end
  end

  def activate(force, &block)
    activate_support_devs do
      cleanup_cache
      activate_top_level(force, &block)
    end
  end

  def is_wb?
    true
  end

  def drop_caches
    return unless is_wb?
    cleanup_forcibly

    # We need the sync daemon works while waiting for dirty
    # caches all written back. Otherwise drop_caches message
    # may never return because of dirty caches remain on RAM
    # buffer that is submitted from upper layer after
    # drop_caches started.
    @wb.message(0, "sync_data_interval", 1)
    @wb.message(0, "drop_caches")
  end

  class Args
    TUNABLES = [:writeback_threshold,
                :nr_max_batched_writeback,
                :update_sb_record_interval,
                :sync_data_interval,
                :read_cache_threshold,
    ]
    def pop
      k, v = @opts.first
      @tunables[k] = v
      @opts.delete k
    end
    def initialize(opts)
      @tunables = {}

      @opts = opts.clone
      until @opts.empty?
        pop
      end
    end
    # {k1=>v1, k2=>v2} -> [N k1 v1 k2 v2]
    def h_to_a(h)
      a = [h.size * 2]
      h.each do |k, v|
        a += [k, v]
      end
      a
    end
    def to_a
      h_to_a(@tunables) unless @tunables.empty?
    end
  end
end

class WriteboostStackBackingDevice < WriteboostStack
  def is_wb?
    false
  end

  def table
    # We won't wrap another linear above backing_dev to avoid unreasonable overhead.
    # Our Writeboost'd devices use once-wrapped linear device.
    Table.new(LinearTarget.new(backing_sz, @slow_dev_name, 0))
  end
end

class WriteboostStackCaching < WriteboostStack
  def table
    essentials = [@backing_dev, @cache_dev]
    args = Args.new(@table_extra_args)
    Table.new(WriteboostTarget.new(backing_sz, essentials + args.to_a))
  end
end
