#!/usr/bin/env ruby
# Static file server with live reload, using only Ruby's standard library
# (WEBrick). Serves the repo root and injects a small script into HTML
# pages that polls for file changes and reloads the page when one occurs.

require 'webrick'
require 'json'

ROOT = File.expand_path('..', __dir__)
WATCH_EXTS = %w[.html .css .js]
IGNORE_DIRS = %w[.git scripts node_modules]
POLL_INTERVAL = 0.5
PORT = (ARGV[0] || 5500).to_i

INJECT_SNIPPET = <<~HTML
  <script>
  (function() {
    var lastVersion = null;
    function poll() {
      fetch('/__livereload', {cache: 'no-store'}).then(function(r) { return r.json(); }).then(function(data) {
        if (lastVersion === null) { lastVersion = data.version; }
        else if (data.version !== lastVersion) { location.reload(); return; }
        setTimeout(poll, 500);
      }).catch(function() { setTimeout(poll, 1000); });
    }
    poll();
  })();
  </script>
HTML

$version = 0
$mtimes = {}
$mutex = Mutex.new

def watched_files
  Dir.glob(File.join(ROOT, '**', '*')).reject do |f|
    IGNORE_DIRS.any? { |d| f.split(File::SEPARATOR).include?(d) }
  end.select { |f| File.file?(f) && WATCH_EXTS.include?(File.extname(f)) }
end

def scan_and_bump
  changed = false
  watched_files.each do |f|
    mtime = File.mtime(f).to_f
    prev = $mtimes[f]
    if prev.nil?
      $mtimes[f] = mtime
    elsif mtime != prev
      $mtimes[f] = mtime
      changed = true
    end
  end
  if changed
    $mutex.synchronize { $version += 1 }
  end
end

Thread.new do
  scan_and_bump
  loop do
    sleep POLL_INTERVAL
    scan_and_bump
  end
end

class LiveReloadServlet < WEBrick::HTTPServlet::AbstractServlet
  def do_GET(req, res)
    v = $mutex.synchronize { $version }
    res['Content-Type'] = 'application/json'
    res['Cache-Control'] = 'no-store'
    res.body = { version: v }.to_json
  end
end

class InjectingFileHandler < WEBrick::HTTPServlet::FileHandler
  def do_GET(req, res)
    # Prevent conditional-GET 304s so the injected script is never skipped.
    req.header.delete('if-none-match')
    req.header.delete('if-modified-since')
    super
    if res['Content-Type'].to_s.include?('text/html')
      body = res.body
      body = body.read if body.respond_to?(:read)
      if body.is_a?(String)
        body = body.include?('</body>') ? body.sub('</body>', "#{INJECT_SNIPPET}</body>") : body + INJECT_SNIPPET
        res.body = body
        res['Content-Length'] = body.bytesize.to_s
        res['Cache-Control'] = 'no-store'
        res['ETag'] = nil
      end
    end
  end
end

server = WEBrick::HTTPServer.new(
  Port: PORT,
  BindAddress: '127.0.0.1',
  DocumentRoot: ROOT,
  DocumentRootOptions: { FancyIndexing: true },
  Logger: WEBrick::Log.new($stderr),
  AccessLog: []
)

server.mount('/__livereload', LiveReloadServlet)
server.mount('/', InjectingFileHandler, ROOT, { FancyIndexing: true })

trap('INT') { server.shutdown }
trap('TERM') { server.shutdown }

puts "Live-reload server running at http://127.0.0.1:#{PORT} (serving #{ROOT})"
server.start
