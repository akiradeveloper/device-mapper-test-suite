module Kernel
  def bracket(v, release)
    r = nil

    begin
      r = yield(v)
    ensure
      p "bracket release"
      release.call(v)
    end
    r
  end

  def bracket_(release)
    r = nil
    begin
      r = yield
    ensure
      p "bracket_ release"
      release.call
    end
    r
  end

  def protect(v, release)
    r = nil

    begin
      r = yield(v)
    rescue
      release.call(v)
      raise
    end

    r
  end

  def protect_(release)
    r = nil
    begin
      r = yield
    rescue
      release.call
      raise
    end
    r
  end
end
