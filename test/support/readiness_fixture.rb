require_relative "browser_fixture"
require_relative "cache_store"
require "paradem_pdf"
require "fileutils"

module ReadinessFixture
  DATA_IMAGE = "data:image/svg+xml;base64,#{['<svg xmlns="http://www.w3.org/2000/svg" width="80" height="30"><rect width="80" height="30" fill="blue"/></svg>'].pack("m0")}"

  def self.html(scenario, unrelated: false, total: 2, lazy_offscreen: true)
    data = (scenario == "bad-data") ? "data:image/png;base64,Y29ycnVwdA==" : DATA_IMAGE
    sections = (1..total).map do |page|
      images = if page == 1
        %(<img id="normal" src="https://resources.example.test/#{scenario}/normal.svg"><img id="data" src="#{data}"><img id="svg" src="#{DATA_IMAGE}">)
      else
        %(<img id="lazy" loading="lazy" #{'style="position:fixed;top:20000px" onload="this.removeAttribute(\'style\')"' if lazy_offscreen} src="https://resources.example.test/#{scenario}/lazy.svg">)
      end
      %(<section><div class="marker">Body#{page}</div><p>Platform font text</p>#{images}</section>)
    end.join
    <<~HTML
      <!doctype html><html><head><link rel="icon" href="data:,"><link rel="stylesheet" href="https://resources.example.test/#{scenario}/style.css">
      <style>html,body{margin:0;font-size:12px}section:not(:last-child){break-after:page}img{width:80px;height:30px}</style>
      </head><body>#{sections}#{"<script>fetch('https://resources.example.test/#{scenario}/unrelated')</script>" if unrelated}</body></html>
    HTML
  end

  def self.options(landscape: false)
    {format: "Letter", landscape: landscape, print_background: true, emulate_media: "print",
     executable_path: ENV.fetch("PUPPETEER_EXECUTABLE_PATH"), launch_timeout: 20_000,
     request_timeout: 20_000, convert_timeout: 20_000}
  end

  def self.configure(directory)
    BrowserFixture.validate!(ENV)
    FileUtils.mkdir_p(directory)
    Grover.configuration.js_runtime_bin = ["node", "--require", File.expand_path("readiness_observer.cjs", __dir__)]
    Grover.configuration.node_env_vars = {"PARADEM_PDF_BROWSER_RECORD" => File.join(directory, "observer"),
                                         "PARADEM_PDF_READINESS_RECORD" => directory,
                                         "PARADEM_PDF_READINESS_TRACE" => ENV.fetch("PARADEM_PDF_READINESS_TRACE", "0"),
                                         "PARADEM_PDF_TEST_FONT" => ENV.fetch("PARADEM_PDF_TEST_FONT")}
  end

  def self.document(store, scenario: "healthy", landscape: false, unrelated: false, readiness: true, timeout: 20_000, overrides: {}, decoration_failure: false, benchmark: false)
    font = [File.binread(ENV.fetch("PARADEM_PDF_TEST_FONT"))].pack("m0")
    ParademPdf::Document.new(doc_type: "readiness-fixture", origin: "https://documents.example.test/", locale: "en",
      body_html: html(decoration_failure ? "healthy" : scenario, unrelated: unrelated, lazy_offscreen: !benchmark),
      header: ->(page:, total_pages:) { BrowserFixture.html("<div>Header#{page}of#{total_pages}</div>", font, style: "div{position:fixed;top:0}") },
      footer: ->(page:, total_pages:) {
        if decoration_failure
          html(scenario, total: 1)
        else
          BrowserFixture.html("<div>Footer#{page}of#{total_pages}</div>", font, style: "div{position:fixed;bottom:0}")
        end
      },
      options: options(landscape: landscape).merge(overrides), readiness: readiness, readiness_timeout: timeout,
      body_margins: {top: "25mm", bottom: "25mm", left: "15mm", right: "15mm"},
      header_margins: {top: "10mm", bottom: "0mm", left: "15mm", right: "15mm"},
      footer_margins: {top: "0mm", bottom: "10mm", left: "15mm", right: "15mm"},
      concurrency: 1, cache: store, cache_namespace: "readiness-fixture", freshness: "fixture-v1",
      assets_version: Digest::SHA256.file(ENV.fetch("PARADEM_PDF_TEST_FONT")).hexdigest, expires_in: 600)
  end

  def self.records(directory)
    Dir[File.join(directory, "conversion-*.json")].map { |file| JSON.parse(File.read(file)) }.sort_by { |record| record.fetch("events").first.fetch("at") }
  end

  def self.check_records(directory, launches: 1)
    BrowserFixture.check_records(directory, launches)
    records(directory).each do |record|
      names = record.fetch("events").map { |event| event.fetch("name") }
      raise "Worker deadline or unclosed context" unless record["contexts"] == 1 && names.count("context-close") == 1 && names.count("disconnect") == 1 && !names.include?("worker-deadline")
    end
  end

  def self.run(directory, scenario)
    configure(directory)
    store = TestCacheStore.new
    store.write("independent", "existing", expires_in: 600)
    store.writes.clear
    overrides = {}
    readiness = scenario != "optout" && scenario != "idle-control"
    overrides[:request_timeout] = 1200 if scenario == "idle-control"
    overrides[:waitUntil] = "domcontentloaded" if scenario == "explicit-wait"
    # These cases also prove the gem preserves explicit screen selection.
    # Portrait/landscape and corrupt-font cases exercise print selection.
    overrides[:emulate_media] = "screen" if %w[screen held custom explicit-wait optout].include?(scenario)
    selected_print = overrides.fetch(:emulate_media, "print") == "print"
    if scenario == "custom"
      overrides[:executeScript] = "(async()=>{window.customCount=(window.customCount||0)+1;await new Promise(r=>setTimeout(r,150));const images=[...document.images];images.forEach(i=>i.loading='eager');await Promise.all(images.map(i=>i.decode()));void document.body.offsetHeight;await document.fonts.ready;window.customDone=true})()"
    end
    landscape = scenario == "landscape"
    resources = %w[bad-font bad-image bad-data bad-style stall].include?(scenario) ? scenario : "healthy"
    decoration_failure = scenario == "bad-decoration"
    resources = "bad-image" if decoration_failure
    doc = document(store, scenario: resources, landscape: landscape,
      unrelated: %w[held idle-control].include?(scenario), readiness: readiness,
      timeout: (scenario == "stall") ? 350 : 20_000, overrides: overrides, decoration_failure: decoration_failure, benchmark: scenario == "optout")
    error = nil
    begin
      bytes = doc.to_pdf
    rescue => exception
      error = exception.message
    end
    File.binwrite(File.join(directory, "actual.pdf"), bytes) if bytes
    File.write(File.join(directory, "render-result.json"), JSON.pretty_generate(error: error, writes: store.writes.map(&:first)))
    check_records(directory)
    conversions = records(directory)
    failed = %w[bad-font bad-image bad-data bad-style stall idle-control bad-decoration].include?(scenario)
    if failed
      expected = {"bad-font" => "PDF font failed", "bad-image" => "PDF image failed", "bad-data" => "PDF image failed",
                  "bad-style" => "https://resources.example.test/bad-style/style.css", "stall" => "PDF readiness timeout", "idle-control" => "Navigation timeout", "bad-decoration" => "PDF image failed"}.fetch(scenario)
      raise "Wrong failure: #{error.inspect}" unless error&.include?(expected)
      raise "Failed render published cache entries" unless store.writes.empty? && store.entries == {"independent" => ["existing", 600]}
      failing = decoration_failure ? conversions.select { |record| record["events"].any? { |event| event["name"] == "script-error" } } : conversions
      raise "Failed conversion printed" if failing.empty? || failing.any? { |record| record["events"].any? { |event| event["name"] == "print-start" } }
    else
      raise "Unexpected render failure: #{error}" if error
      raise "Wrong actual conversion count" unless conversions.length == 5
      body = conversions.find { |record| record.fetch("snapshot").fetch("images").length == 4 }
      raise "No body observation" unless body
      snapshot = body.fetch("snapshot")
      raise "Premature image print" unless snapshot.fetch("images").all? { |image| image["width"] > 0 }
      if readiness && scenario != "custom"
        raise "Lazy image not promoted" unless snapshot["images"].all? { |image| image["loading"] == "eager" }
      end
      raise "Media override lost" unless snapshot["print"] == selected_print
      if selected_print
        raise "Premature font print" unless snapshot["fonts"].any? { |face| face["family"] == "Fixture" && face["status"] == "loaded" }
      end
      raise "Unused font not allowed" unless snapshot["fonts"].any? { |face| face["family"] == "Unused" && face["status"] == "unloaded" }
      raise "Stylesheet not applied" unless snapshot["markerLeft"] == 48
      names = body["events"].map { |event| event["name"] }
      if scenario == "held"
        print = body["events"].find { |event| event["name"] == "print-start" }
        raise "Unrelated fetch not held through print" unless print["unrelatedPending"] && names.index("unrelated-held") < names.index("print-start") && names.index("print-start") < names.index("unrelated-release")
      end
      if scenario == "custom"
        conversions.each do |conversion|
          script_events = conversion["events"].map { |event| event["name"] }
          state = conversion.fetch("snapshot")
          raise "Custom script repeated or unawaited" unless state["customCount"] == 1 && state["customDone"] && script_events.count("script-start") == 1 && script_events.index("script-end") < script_events.index("print-start")
        end
      end
      if scenario == "explicit-wait"
        raise "Explicit wait lost" unless body["waitUntil"] == "domcontentloaded"
      elsif !readiness
        raise "Opt-out lost native waiting" unless body["waitUntil"] == "networkidle0" && !names.include?("script-start")
      end
      dimensions = landscape ? [0, 0, 792, 612] : [0, 0, 612, 792]
      BrowserFixture.check_document(bytes, 2, landscape, dimensions, directory, "document")
      if selected_print
        raise "Required font not embedded" unless BrowserFixture.run("pdffonts", File.join(directory, "document.pdf")).include?("Arial")
      end
      before = conversions.length
      raise "Hot cache changed bytes" unless doc.to_pdf == bytes
      raise "Hot cache converted" unless records(directory).length == before
    end
    result = {scenario: scenario, error: error, conversions: conversions.length, writes: store.writes.length}
    File.write(File.join(directory, "result.json"), JSON.pretty_generate(result))
    puts JSON.generate(result)
  end

  def self.media_regression(directory)
    configure(directory)
    failures = []
    store = TestCacheStore.new
    ParademPdf::Document.browser(options: options) do |browser|
      10.times do |iteration|
        ["healthy", "bad-font"].each do |scenario|
          before = records(directory).length
          writes = store.writes.length
          doc = ParademPdf::Document.new(doc_type: "media-regression-#{iteration}-#{scenario}",
            body_html: html(scenario, lazy_offscreen: false), origin: "https://documents.example.test/", locale: "en",
            options: options, concurrency: 1, cache: store, cache_namespace: "media-regression", freshness: "fixture-v1",
            assets_version: "platform-font", expires_in: 600)
          error = nil
          begin
            doc.to_pdf(browser: browser)
          rescue => exception
            error = exception.message
          end
          record = records(directory).drop(before).fetch(0)
          phases = [record["media_after_load"], record["media_after_readiness"]]
          phases << record.dig("snapshot", "print") if scenario == "healthy"
          failures << "#{iteration}/#{scenario}: selected print media lost: #{phases.inspect}" unless phases.all?(true)
          if scenario == "healthy"
            failures << "#{iteration}/healthy: #{error}" if error
          else
            failures << "#{iteration}/bad-font: corrupt font accepted or cached" unless error&.include?("PDF font failed") && store.writes.length == writes && !record["snapshot"]
          end
        end
      end
    end
    check_records(directory)
    File.write(File.join(directory, "media-regression.json"), JSON.pretty_generate(iterations: 10, conversions: records(directory).length, failures: failures))
    raise failures.join("\n") unless failures.empty?
    puts JSON.generate(iterations: 10, conversions: records(directory).length, failures: failures)
  end
end

if $PROGRAM_NAME == __FILE__
  abort "Readiness fixture disabled" unless ENV["PARADEM_PDF_READINESS_BROWSER"] == "1"
  ReadinessFixture.run(ARGV.fetch(1), ARGV.fetch(2)) if ARGV.first == "--render"
  ReadinessFixture.media_regression(ARGV.fetch(1)) if ARGV.first == "--media-regression"
end
