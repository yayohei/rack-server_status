require 'rack/server_status/version'
require 'json'
require 'worker_scoreboard'
require 'logger'
require 'ltsv_log_formatter'

module Rack
  class ServerStatus
    def initialize(app, options = {})
      @app             = app
      @uptime          = Time.now.to_i
      @skip_ps_command = options[:skip_ps_command] || false
      @path            = options[:path]            || '/server-status'
      @allow           = options[:allow]           || []
      @perf_log        = options[:perf_log_path]   || false
      @perf_log_path   = options[:perf_log_path]   || './server_status.log'
      @perf_rss        = options[:perf_rss].to_i
      @perf_ss         = options[:perf_ss].to_i
      @logger          = logger
      scoreboard_path  = options[:scoreboard_path]
      unless scoreboard_path.nil?
        @scoreboard = WorkerScoreboard.new(scoreboard_path)
      end
    end

    def call(env)
      start_time = Time.now.to_i
      start_rss  = `ps -o rss= -p #{Process.pid}`.to_i

      set_state!('A', env, start_time, start_rss)

      if env['PATH_INFO'] == @path
        handle_server_status(env)
      else
        @app.call(env)
      end
    ensure
      set_state!('_')
      status_logging(env, start_time, start_rss)
    end

    private

    def set_state!(status = '_', env = nil, start_time = nil, start_rss = nil)
      return if @scoreboard.nil?
      prev = {}
      unless env.nil?
        prev = {
          remote_addr: env['REMOTE_ADDR'],
          host:        env['HTTP_HOST'] || '-',
          method:      env['REQUEST_METHOD'],
          uri:         env['REQUEST_URI'],
          protocol:    env['SERVER_PROTOCOL'],
          time:        start_time,
          start_rss:   start_rss,
        }
      end
      prev[:pid]    = Process.pid
      prev[:ppid]   = Process.ppid
      prev[:uptime] = @uptime
      prev[:status] = status

      @scoreboard.update(prev.to_json)
    end

    def status_logging(env, start_time, start_rss)
      rss = `ps -o rss= -p #{Process.pid}`.to_i
      ss  = Time.now.to_i - start_time
      if @perf_log && rss > @perf_rss || ss > @perf_ss
        stat = {
          remote_addr: env['REMOTE_ADDR'],
          host:        env['HTTP_HOST'] || '-',
          method:      env['REQUEST_METHOD'],
          uri:         env['REQUEST_URI'],
          protocol:    env['SERVER_PROTOCOL'],
          pid:         Process.pid,
          ppid:        Process.ppid,
          ss:          ss,
          rss:         rss,
          inc_rss:     rss - start_rss,
        }
        @logger.info stat
      end
    end

    def allowed?(address)
      return true if @allow.empty?
      @allow.include?(address)
    end

    def handle_server_status(env)
      unless allowed?(env['REMOTE_ADDR'])
        return [403, {'content-type' => 'text/plain'}, [ 'Forbidden' ]]
      end

      upsince = Time.now.to_i - @uptime
      duration = "#{upsince} seconds"
      body = "Uptime: #{@uptime} (#{duration})\n"
      status = {Uptime: @uptime}

      unless @scoreboard.nil?
        stats = @scoreboard.read_all
        parent_pid = Process.ppid
        all_workers = {}
        idle = 0
        busy = 0
        if @skip_ps_command
          all_workers = stats.keys.map { |k| [k, 0] }.to_h
        elsif RUBY_PLATFORM !~ /mswin(?!ce)|mingw|cygwin|bccwin/
          ps = `LC_ALL=C command ps -e -o ppid,pid,rss`
          ps.each_line do |line|
            line.lstrip!
            next if line =~ /^\D/
            ppid, pid, rss = line.chomp.split(/\s+/, 3).map { |x| x.chomp.to_i }
            all_workers[pid] = rss if ppid.to_i == parent_pid
          end
        else
          all_workers = stats.keys.map { |k| [k, 0] }.to_h
        end
        process_status_str = ''
        process_status_list = []

        all_workers.each do |pid, rss|
          json =stats[pid] || '{}'
          pstatus = begin; JSON.parse(json, symbolize_names: true); rescue; end
          pstatus ||= {}
          if !pstatus[:status].nil? && pstatus[:status] == 'A'
            busy += 1
          else
            idle += 1
          end
          unless pstatus[:time].nil?
            pstatus[:ss] = Time.now.to_i - pstatus[:time].to_i
          end
          pstatus[:pid] ||= pid
          pstatus[:rss] ||= rss
          unless pstatus[:start_rss].nil?
            pstatus[:inc_rss] = rss - pstatus[:start_rss].to_i
          end
          pstatus.delete :time
          pstatus.delete :ppid
          pstatus.delete :uptime
          process_status_str << sprintf("%s\n", [:pid, :status, :remote_addr, :host, :method, :uri, :protocol, :ss, :rss, :inc_rss].map {|item| pstatus[item] || '' }.join(' '))
          process_status_list << pstatus
        end
        body << <<"EOF"
BusyWorkers: #{busy}
IdleWorkers: #{idle}
--
pid status remote_addr host method uri protocol ss rss inc_rss
#{process_status_str}
EOF
        body.chomp!
        status[:BusyWorkers] = busy
        status[:IdleWorkers] = idle
        status[:stats]       = process_status_list
      else
        body << "WARN: Scoreboard has been disabled\n"
        status[:WARN] = 'Scoreboard has been disabled'
      end
      if (env['QUERY_STRING'] || '') =~ /\bjson\b/
        return [200, {'content-type' => 'application/json; charset=utf-8'}, [status.to_json]]
      end
      return [200, {'content-type' => 'text/plain'}, [body]]
    end

    def logger
      logger = ::Logger.new(@perf_log_path || nil)
      logger.formatter = LtsvLogFormatter.new
      logger
    end
  end
end
