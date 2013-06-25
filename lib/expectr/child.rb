require 'pty'
require 'expectr/interface'

class Expectr
  # Internal: The Expectr::Child class contains the interface to interacting
  # with child processes.
  #
  # All methods with the prefix 'interface_' in their name will return a Proc
  # designed to be defined as an instance method in the primary Expectr object.
  # These methods will all be documented as if they are the Proc in question.
  class Child
    include Expectr::Interface
    attr_reader :stdin
    attr_reader :stdout
    attr_reader :pid

    # Public: Initialize a new Expectr::Child object.
    # Spawns a sub-process and attaches to STDIN and STDOUT for the new
    # process.
    #
    # cmd - A String or File referencing the application to launch.
    #
    # Raises TypeError if argument is anything other than String or File.
    def initialize(cmd)
      cmd = cmd.path if cmd.kind_of?(File)
      unless cmd.kind_of?(String)
        raise(TypeError, Errstr::STRING_FILE_EXPECTED)
      end

      @stdout,@stdin,@pid = PTY.spawn(cmd)
      @stdout.winsize = $stdout.winsize if $stdout.tty?
    end

    # Public: Send a signal to the running child process.
    #
    # signal - Symbol, String or FixNum corresponding to the symbol to be sent
    # to the running process. (default: :TERM)
    #
    # Returns a boolean indicating whether the process was successfully sent
    # the signal.
    # Raises ProcessError if the process is not running (@pid = 0).
    def interface_kill!
      ->(signal = :TERM) {
        unless @pid > 0
          raise(ProcessError, Errstr::PROCESS_NOT_RUNNING)
        end
        Process::kill(signal.to_sym, @pid) == 1
      }
    end

    # Public: Send input to the active child process.
    #
    # str - String to be sent.
    #
    # Returns nothing.
    # Raises Expectr::ProcessError if the process is not running (@pid = 0)
    def interface_send
      ->(str) {
        begin
          @stdin.syswrite str
        rescue Errno::EIO #Application is not running
          @pid = 0
        end
        unless @pid > 0
          raise(Expectr::ProcessError, Errstr::PROCESS_GONE)
        end
      }
    end

    # Public: Read the child process's output, force UTF-8 encoding, then
    # append to the internal buffer and print to $stdout if appropriate.
    #
    # Returns nothing.
    def interface_output_loop
      -> {
        while @pid > 0
          unless select([@stdout], nil, nil, @timeout).nil?
            buf = ''

            begin
              @stdout.sysread(@buffer_size, buf)
            rescue Errno::EIO #Application is not running
              @pid = 0
              return
            end
            process_output(buf)
          end
        end
      }
    end

    def interface_prepare_interact_environment
      -> {
        env = {sig: {}}

        # Save old tty settings and set up the new environment
        env[:tty] = `stty -g`
        `stty -icanon min 1 time 0 -echo`

        # SIGINT should be sent to the child as \C-c
        env[:sig]['INT'] = trap 'INT' do
          send "\C-c"
        end

        # SIGTSTP should be sent to the process as \C-z
        env[:sig]['TSTP'] = trap 'TSTP' do
          send "\C-z"
        end

        # SIGWINCH should trigger an update to the child processes window size
        env[:sig]['WINCH'] = trap 'WINCH' do
          @stdout.winsize = $stdout.winsize
        end

        env
      }
    end

    # Public: Create a Thread containing the loop which is responsible for
    # handling input from the user in interact mode.
    #
    # Returns a Thread containing the running loop.
    def interface_interact_thread
      -> {
        @interact = true
        env = prepare_interact_environment
        Thread.new do
          begin
            input = ''

            while @pid > 0 && @interact
              if select([$stdin], nil, nil, 1)
                c = $stdin.getc.chr
                send c unless c.nil?
              end
            end
          ensure
            restore_environment(env)
          end
        end
      }
    end

    # Public: Return the PTY's window size.
    #
    # Returns a two-element Array (same as IO#winsize)
    def interface_winsize
      -> {
        @stdout.winsize
      }
    end

    # Public: Present a streamlined interface to create a new Expectr instance.
    #
    # cmd  - A String or File referencing the application to launch.
    # args - A Hash used to specify options for the new object, per
    #        Expectr#initialize.
    #
    # Returns a new Expectr object
    def self.spawn(cmd, args = {})
      args[:interface] = :child
      Expectr.new(cmd, args)
    end
  end
end