require 'json'
require 'net/http'
require 'socket'
require 'tmpdir'
require_relative '../storage/sqlite_index'

def test_launcher_preserves_relative_index_paths
  launcher = File.expand_path('../scripts/start-server.ps1', __dir__)
  powershell = File.join(ENV.fetch('SystemRoot'), 'System32/WindowsPowerShell/v1.0/powershell.exe')
  raise 'Windows PowerShell is required for the launcher test' unless File.file?(powershell)
  Dir.mktmpdir('launcher-', __dir__) do |dir|
    raise 'Unexpected temporary directory' unless File.realpath(dir).start_with?(File.realpath(__dir__) + '/')
    store = SqliteIndex.new(File.join(dir, 'relative.sqlite'), 'chunks')
    begin
      store.upsert_chunks([{path: File.join(dir, 'note.md'), chunk: 0, hash: 'fixture',
        text: 'Expected caller directory index.', embedding: [1.0, 0.0], bucket: 1}])
    ensure
      store.close
    end
    config = File.join(dir, 'config.json')
    File.write(config, JSON.generate(
      embedding: {provider: 'openai', model: 'unused'},
      paths: [{name: 'notes', reader: 'text', dir: '.', db: 'relative.sqlite@chunks', searchDefault: true}]
    ))
    listener = TCPServer.new('127.0.0.1', 0)
    port = listener.addr[1]
    listener.close
    pid = nil
    begin
      # Let Windows PowerShell use its own module paths, not an inherited PS7 list.
      stdout_path = File.join(dir, 'launcher.stdout')
      stderr_path = File.join(dir, 'launcher.stderr')
      # File redirection avoids waiting for pipe handles inherited by the detached server.
      launcher_pid = Process.spawn({'DOT_OPENAI_KEY' => 'test', 'PSModulePath' => nil}, powershell,
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', launcher, '-Config', config,
        '-Port', port.to_s, '-LogDirectory', File.join(dir, 'logs'), chdir: dir,
        out: stdout_path, err: stderr_path)
      _, status = Process.wait2(launcher_pid)
      stdout = File.read(stdout_path)
      stderr = File.read(stderr_path)
      match = stdout.match(/PID (\d+)/)
      pid = match[1].to_i if match
      raise "Launcher failed: #{stdout}\n#{stderr}" unless status.success? && pid
      uri = URI("http://127.0.0.1:#{port}/random")
      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 5) do |http|
        http.post(uri.path, JSON.generate(paths: ['notes'], count: 1), 'Content-Type' => 'application/json')
      end
      raise "Random request failed: #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      data = JSON.parse(response.body).fetch('data')
      raise "Wrong index opened: #{data.inspect}" unless data.length == 1 && data.first['text'] == 'Expected caller directory index.'
    ensure
      if pid
        Process.kill('KILL', pid) rescue Errno::ESRCH
        # Windows releases SQLite/log handles asynchronously after termination.
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        loop do
          begin
            Process.kill(0, pid)
          rescue Errno::ESRCH
            break
          end
          raise 'Test server did not stop' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          sleep 0.05
        end
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  if Gem.win_platform?
    test_launcher_preserves_relative_index_paths
    puts 'start_server_test: passed'
  else
    puts 'start_server_test: skipped (Windows launcher)'
  end
end
