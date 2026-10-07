require "open3"
require "digest"
require "json"
require "nokogiri"

module BrowserFixture
  def self.check_delta(before, after, **expected)
    expected.each do |kind, count|
      actual = after.fetch(kind) - before.fetch(kind)
      raise "Unexpected #{kind}: expected #{count}, got #{actual}" unless actual == count
    end
  end

  def self.snapshot(captures, callbacks, directory)
    {conversions: captures.length, callbacks: callbacks.length,
     launches: Dir[File.join(directory, "observer-*.json")].length}
  end

  def self.check_parts(captures, directory)
    captures.each_with_index do |bytes, index|
      path = File.join(directory, "part-#{index}.pdf")
      File.binwrite(path, bytes)
      check_fonts(path)
    end
  end

  def self.validate!(env)
    if env["GROVER_NO_SANDBOX"] == "true" || !env.fetch("NODE_OPTIONS", "").empty?
      raise ArgumentError, "Unsafe browser security environment"
    end
    font = env["PARADEM_PDF_TEST_FONT"]
    raise ArgumentError, "PARADEM_PDF_TEST_FONT must be a readable platform font" unless font && File.file?(font) && File.readable?(font)
    chrome = env["PUPPETEER_EXECUTABLE_PATH"]
    raise ArgumentError, "PUPPETEER_EXECUTABLE_PATH must be executable" unless chrome && File.file?(chrome) && File.executable?(chrome)
    %w[node pdffonts pdftotext].each do |command|
      unless env.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |path| File.executable?(File.join(path, command)) }
        raise ArgumentError, "Missing browser prerequisite: #{command}"
      end
    end
    run("node", "-e", "require(require.resolve('puppeteer', {paths: require('module')._nodeModulePaths(process.cwd())}))")
  end

  def self.run(*command, timeout: 20)
    Open3.popen3(*command) do |input, output, errors, waiter|
      input.close
      stdout = Thread.new { output.read }
      stderr = Thread.new { errors.read }
      unless waiter.join(timeout)
        Process.kill("KILL", waiter.pid) if waiter.alive?
        waiter.join
        raise "Command deadline: #{command.first}"
      end
      text = stdout.value
      error = stderr.value
      raise "Command failed: #{command.first}: #{error}\n#{text}" unless waiter.value.success?
      text
    end
  end

  def self.html(content, font, style: "")
    <<~HTML
      <!doctype html><html><head><link rel="icon" href="data:,"><style>
        @font-face { font-family: Fixture; src: url(data:font/ttf;base64,#{font}); }
        html, body { margin: 0; font-family: Fixture; font-size: 12px; }
        #{style}
      </style></head><body>#{content}</body></html>
    HTML
  end

  def self.check_fonts(path)
    rows = run("pdffonts", path).lines.drop(2).reject { |line| line.strip.empty? }
    raise "No embedded fonts in #{path}" if rows.empty? || rows.any? { |line| !line.match?(/\s+yes\s+(?:yes|no)\s+(?:yes|no)\s+\d+\s+\d+\s*$/) }
  end

  def self.check_positions(path, total, landscape)
    xml = Nokogiri::XML(run("pdftotext", "-bbox", path, "-")) { |config| config.strict.nonet }
    pages = xml.xpath("//*[local-name()='page']")
    raise "Wrong text page count" unless pages.length == total
    width, height = landscape ? [792, 612] : [612, 792]
    pages.each_with_index do |page, index|
      unless (page["width"].to_f - width).abs < 0.1 && (page["height"].to_f - height).abs < 0.1
        raise "Wrong text geometry"
      end
      words = page.xpath(".//*[local-name()='word']")
      header = words.select { |word| word.text.start_with?("Header") }
      footer = words.select { |word| word.text.start_with?("Footer") }
      body = words.reject { |word| (header + footer).include?(word) }
      unless header.map(&:text) == ["Header#{index + 1}of#{total}"] && footer.map(&:text) == ["Footer#{index + 1}of#{total}"] && body.map(&:text).include?("Body#{index + 1}")
        raise "Wrong page labels or stale total"
      end
      unless header.all? { |word| word["yMin"].to_f > 10 && word["yMax"].to_f < 60 } &&
          footer.all? { |word| word["yMin"].to_f > height - 60 && word["yMax"].to_f < height - 10 } &&
          body.all? { |word| word["yMin"].to_f >= 60 && word["yMax"].to_f <= height - 60 }
        raise "Text outside reserved header/body/footer bands"
      end
    end
  end

  def self.render(directory, landscape)
    validate!(ENV)
    require "paradem_pdf"
    require_relative "cache_store"
    captures = []
    Grover::Processor.prepend(Module.new do
      define_method(:convert) do |kind, html, options|
        bytes = super(kind, html, options)
        captures << bytes
        bytes
      end
    end)
    observer = File.expand_path("browser_observer.cjs", __dir__)
    Grover.configuration.js_runtime_bin = ["node", "--require", observer]
    font_bytes = File.binread(ENV.fetch("PARADEM_PDF_TEST_FONT"))
    dimensions = landscape ? [0, 0, 792, 612] : [0, 0, 612, 792]

    per_render_dir = File.join(directory, "per-render")
    Dir.mkdir(per_render_dir)
    Grover.configuration.node_env_vars = {"PARADEM_PDF_BROWSER_RECORD" => File.join(per_render_dir, "observer")}
    store = TestCacheStore.new
    callbacks = []
    [2, 3].each do |total|
      before = snapshot(captures, callbacks, per_render_dir)
      document, bytes = render_document(total, landscape, font_bytes, dimensions, per_render_dir, store, callbacks: callbacks)
      check_delta(before, snapshot(captures, callbacks, per_render_dir), conversions: 1 + 2 * total, callbacks: 2 * total, launches: 1)

      before = snapshot(captures, callbacks, per_render_dir)
      raise "Completed hit changed bytes" unless document.to_pdf == bytes
      check_delta(before, snapshot(captures, callbacks, per_render_dir), conversions: 0, callbacks: 0, launches: 0)

      store.entries.delete(store.writes.last.first)
      before = snapshot(captures, callbacks, per_render_dir)
      warm = document.to_pdf
      check_delta(before, snapshot(captures, callbacks, per_render_dir), conversions: 1, callbacks: 2 * total, launches: 1)
      check_document(warm, total, landscape, dimensions, per_render_dir, "warm-#{total}")
    end
    per_render_conversions = captures.length
    raise "Expected cold parts and two warm body conversions" unless per_render_conversions == 14
    cleanups = check_records(per_render_dir, 4)
    check_parts(captures, per_render_dir)

    captures.clear
    batch_dir = File.join(directory, "batch")
    Dir.mkdir(batch_dir)
    Grover.configuration.node_env_vars = {"PARADEM_PDF_BROWSER_RECORD" => File.join(batch_dir, "observer")}
    store = TestCacheStore.new
    ParademPdf::Document.browser(options: {executable_path: ENV.fetch("PUPPETEER_EXECUTABLE_PATH"), launch_timeout: 20_000}) do |browser|
      [2, 3].each { |total| render_document(total, landscape, font_bytes, dimensions, batch_dir, store, browser: browser) }
    end
    raise "Expected actual body and all separate decorations" unless captures.length == 12
    batch_cleanups = check_records(batch_dir, 1)

    check_parts(captures, batch_dir)
    puts JSON.generate(pages: [2, 3], conversions: captures.length,
      per_render_conversions: per_render_conversions, completed_hits: 2, warm_bodies: 2,
      cleanups: cleanups, batch_cleanups: batch_cleanups)
  end

  def self.render_document(total, landscape, font_bytes, dimensions, directory, store, browser: nil, callbacks: [])
    font = [font_bytes].pack("m0")
    sections = (1..total).map { |page| "<section>Body#{page}<p>Platform font text</p></section>" }.join
    body = html(sections, font, style: "section:not(:last-child) { break-after: page; }")
    document = ParademPdf::Document.new(
      doc_type: "browser-fixture", body_html: body, origin: "https://documents.example.test/", locale: "en",
      header: ->(page:, total_pages:) {
        callbacks << [:header, page, total_pages]
        html("<div>Header#{page}of#{total_pages}</div>", font, style: "div { position: fixed; top: 0; }")
      },
      footer: ->(page:, total_pages:) {
        callbacks << [:footer, page, total_pages]
        html("<div>Footer#{page}of#{total_pages}</div>", font, style: "div { position: fixed; bottom: 0; }")
      },
      options: {format: "Letter", landscape: landscape, print_background: true,
                executable_path: ENV.fetch("PUPPETEER_EXECUTABLE_PATH"), launch_timeout: 20_000,
                request_timeout: 20_000, convert_timeout: 20_000},
      body_margins: {top: "25mm", bottom: "25mm", left: "15mm", right: "15mm"},
      header_margins: {top: "10mm", bottom: "0mm", left: "15mm", right: "15mm"},
      footer_margins: {top: "0mm", bottom: "10mm", left: "15mm", right: "15mm"},
      cache: store, cache_namespace: "browser-fixture", freshness: "fixture-v1",
      assets_version: Digest::SHA256.hexdigest(font_bytes), expires_in: 60
    )
    bytes = document.to_pdf(browser: browser)
    check_document(bytes, total, landscape, dimensions, directory, "document-#{total}")
    [document, bytes]
  end

  def self.check_document(bytes, total, landscape, dimensions, directory, name)
    pdf = CombinePDF.parse(bytes)
    if pdf.pages.length != total || pdf.pages.any? { |page| page[:MediaBox] != dimensions || (page[:Rotate] || 0) % 360 != 0 }
      raise "Wrong PDF page count or geometry"
    end
    path = File.join(directory, "#{name}.pdf")
    File.binwrite(path, bytes)
    check_fonts(path)
    check_positions(path, total, landscape)
  end

  def self.check_records(directory, expected)
    records = Dir[File.join(directory, "observer-*.json")].map { |path| JSON.parse(File.read(path)) }
    clean = records.all? do |record|
      cleanup = record.fetch("cleanup")
      !record["error"] && cleanup["closed"] && !cleanup["forced"] && !cleanup["error"] &&
        cleanup["reaped"] == {"code" => 0, "signal" => nil}
    end
    raise "Missing or failed owned browser cleanup" unless records.length == expected && clean
    records.length
  end
end

if $PROGRAM_NAME == __FILE__ && ARGV.first == "--render"
  abort "Browser fixture is disabled" unless ENV["PARADEM_PDF_BROWSER"] == "1"
  BrowserFixture.render(ARGV.fetch(1), ARGV.fetch(2) == "landscape")
end
