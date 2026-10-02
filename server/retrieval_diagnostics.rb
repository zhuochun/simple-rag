require "thread"

module SimpleRag
  # One collector per invocation; worker threads only append completed samples.
  class RetrievalDiagnostics
    def initialize
      @samples = { "embeddings" => [], "searches" => [] }
      @mutex = Mutex.new
    end

    def measure(kind, labels)
      sample = labels.merge("status" => "ok")
      started = clock
      yield sample
    rescue => error
      sample["status"] = "error"
      sample["error_class"] = error.class.name
      raise
    ensure
      sample["elapsed_ms"] = ((clock - started) * 1000.0).round(3)
      @mutex.synchronize { @samples.fetch(kind) << sample }
    end

    def snapshot
      @samples.transform_values do |samples|
        samples.sort_by { |sample| [sample["source_list"], sample["lookup"].to_s] }
      end
    end

    private

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
