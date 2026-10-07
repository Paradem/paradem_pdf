class TestCacheStore
  attr_reader :entries, :writes, :reads
  attr_accessor :write_result, :read_error, :write_error, :now

  def initialize
    @entries = {}
    @writes = []
    @reads = []
    @write_result = true
    @now = 0
  end

  def read(key)
    raise read_error if read_error
    @reads << key
    bytes, deadline = entries[key]
    bytes if deadline && deadline > now
  end

  def write(key, bytes, expires_in:)
    raise write_error if write_error
    writes << [key, bytes, expires_in]
    entries[key] = [bytes, now + expires_in] if write_result
    write_result
  end
end
