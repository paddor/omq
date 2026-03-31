# frozen_string_literal: true

require "async"

module OMQ
  # Shared IO reactor for the Ruby backend.
  #
  # When user code runs inside an Async reactor, engine tasks are
  # spawned directly under the caller's Async task. When no reactor
  # is available (e.g. bare Thread.new), a single shared IO thread
  # hosts all engine tasks — mirroring libzmq's IO thread.
  #
  # Engines obtain the IO thread's root task via {.root_task} and
  # use it as their @parent_task. Blocking operations from the main
  # thread are dispatched to the IO thread via {.run}.
  #
  module Reactor
    @mutex      = Mutex.new
    @thread     = nil
    @root_task  = nil
    @work_queue = nil
    @max_linger = 0

    class << self
      # Returns the root Async task inside the shared IO thread.
      # Starts the thread exactly once (double-checked lock).
      #
      # @return [Async::Task]
      #
      def root_task
        return @root_task if @root_task
        @mutex.synchronize do
          return @root_task if @root_task
          ready       = Thread::Queue.new
          @work_queue = Async::Queue.new
          @thread     = Thread.new { run_reactor(ready) }
          @thread.name = "omq-io"
          @root_task = ready.pop
          at_exit { stop! }
        end
        @root_task
      end


      # Runs a block inside the Async reactor.
      #
      # Inside an Async reactor: runs directly.
      # Outside: dispatches to the shared IO thread and blocks
      # the calling thread until the result is available.
      #
      # @return [Object] the block's return value
      #
      def run(&block)
        if Async::Task.current?
          yield
        else
          result = Thread::Queue.new
          root_task # ensure started
          @work_queue.push([block, result])
          status, value = result.pop
          raise value if status == :error
          value
        end
      end


      # Tracks the longest linger across all sockets on this thread.
      #
      # @param seconds [Numeric, nil] linger value (nil = unbounded)
      #
      def track_linger(seconds)
        @max_linger = [seconds || 0, @max_linger].max
      end


      # Stops the shared IO thread.
      #
      # @return [void]
      #
      def stop!
        return unless @thread&.alive?
        @work_queue&.push(nil)
        @thread&.join(@max_linger + 1)
        @thread     = nil
        @root_task  = nil
        @work_queue = nil
        @max_linger = 0
      end

      private

      # Runs the shared Async reactor.
      #
      # Processes work items dispatched via {.run} while engine
      # tasks (accept loops, pumps, etc.) run as transient children.
      #
      # @param ready [Thread::Queue] receives the root task once started
      #
      def run_reactor(ready)
        Async do |task|
          ready.push(task)
          loop do
            item = @work_queue.dequeue
            break if item.nil?
            block, result = item
            task.async do
              result.push([:ok, block.call])
            rescue => e
              result.push([:error, e])
            end
          end
        end
      end
    end
  end
end
