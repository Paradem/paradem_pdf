require_relative "readiness_fixture"

module ReadinessBenchmark
  def self.clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def self.measure(directory, name)
    before = ReadinessFixture.records(directory).length
    start = clock
    bytes = yield
    total = (clock - start) * 1000
    conversions = ReadinessFixture.records(directory).drop(before)
    phases = %w[navigation readiness print].to_h do |phase|
      [phase, conversions.sum { |record|
        values = record.fetch("phases")
        (values["#{phase}_end"] || 0) - (values["#{phase}_start"] || 0)
      }]
    end
    launches = Dir[File.join(directory, "launch-*.json")].map { |file| JSON.parse(File.read(file)) }
    # Each miss owns exactly one launch; hot hits own none. The warm launch is
    # distinguished by its monotonic start, not filesystem listing order.
    latest = launches.max_by { |record| record.fetch("launch_start") }
    phases["launch"] = conversions.empty? ? 0 : latest.fetch("launch_end") - latest.fetch("launch_start")
    phases["close"] = conversions.empty? ? 0 : latest.fetch("close_end") - latest.fetch("close_start")
    phases["residual"] = total - phases.values.sum
    path = File.join(directory, "#{name}.pdf")
    File.binwrite(path, bytes)
    {total: total, phases: phases, conversions: conversions.length, path: path}
  end

  def self.appearance(path)
    pdf = CombinePDF.load(path)
    xml = Nokogiri::XML(BrowserFixture.run("pdftotext", "-bbox", path, "-")) { |config| config.strict.nonet }
    rows = BrowserFixture.run("pdffonts", path).lines.drop(2).map { |line| line.gsub(/\b[A-Z]{6}\+/, "").sub(/\s+\d+\s+\d+\s*$/, "").strip }.sort
    prefix = path.delete_suffix(".pdf")
    BrowserFixture.run("pdftoppm", "-r", "72", "-png", path, prefix)
    {pages: pdf.pages.map { |page| [page[:MediaBox], page[:Rotate] || 0] },
     text: xml.xpath("//*[local-name()='page']").map(&:to_s), fonts: rows,
     rasters: Dir["#{prefix}-*.png"].sort.map { |file| Digest::SHA256.file(file).hexdigest }}
  end

  def self.distribution(values)
    sorted = values.sort
    {median: (sorted[4] + sorted[5]) / 2, min: sorted.first, max: sorted.last}
  end

  def self.run(directory)
    BrowserFixture.validate!(ENV)
    raise "Missing raster prerequisite" unless ENV.fetch("PATH").split(File::PATH_SEPARATOR).any? { |path| File.executable?(File.join(path, "pdftoppm")) }
    trials = []
    appearances = []
    10.times do |iteration|
      pair = {iteration: iteration + 1, policies: {}}
      policies = iteration.even? ? %w[old new] : %w[new old]
      policies.each do |policy|
        target = File.join(directory, "pair-#{iteration + 1}", policy)
        ReadinessFixture.configure(target)
        store = TestCacheStore.new
        doc = ReadinessFixture.document(store, readiness: policy == "new", benchmark: true)
        cold = measure(target, "cold") { doc.to_pdf }
        raise "Cold did not convert body and decorations" unless cold[:conversions] == 5 && store.writes.length == 5
        completed_key = store.writes.last.first
        store.entries.delete(completed_key)
        warm = measure(target, "warm") { doc.to_pdf }
        raise "Warm did not reuse only decorations" unless warm[:conversions] == 1 && store.writes.length == 6
        hot = measure(target, "hot") { doc.to_pdf }
        raise "Hot converted or wrote" unless hot[:conversions].zero? && store.writes.length == 6
        raise "Hot bytes changed" unless File.binread(hot[:path]) == File.binread(warm[:path])
        ReadinessFixture.check_records(target, launches: 2)
        raise "Unexpected context count" unless ReadinessFixture.records(target).length == 6
        pair[:policies][policy] = {cold: cold, warm: warm, hot: hot}
      end
      %i[cold warm hot].each do |state|
        old = appearance(pair[:policies]["old"][state][:path])
        candidate = appearance(pair[:policies]["new"][state][:path])
        appearances << {iteration: iteration + 1, state: state,
                        matches: old.keys.to_h { |key| [key, old[key] == candidate[key]] }}
      end
      trials << pair
      File.write(File.join(directory, "trials.json"), JSON.pretty_generate(trials))
      puts JSON.generate(iteration: iteration + 1, warm_old: pair[:policies]["old"][:warm][:total], warm_new: pair[:policies]["new"][:warm][:total])
    end
    summary = %w[old new].to_h do |policy|
      [policy, %i[cold warm hot].to_h do |state|
        measurements = trials.map { |pair| pair[:policies][policy][state] }
        [state, {total: distribution(measurements.map { |measurement| measurement[:total] }),
                 phases: measurements.first[:phases].keys.to_h { |phase| [phase, distribution(measurements.map { |measurement| measurement[:phases][phase] })] }}]
      end]
    end
    reductions = %i[cold warm hot].to_h do |state|
      old = summary["old"][state][:total][:median]
      candidate = summary["new"][state][:total][:median]
      [state, 100 * (old - candidate) / old]
    end
    paired = trials.map { |pair| 100 * (pair[:policies]["old"][:warm][:total] - pair[:policies]["new"][:warm][:total]) / pair[:policies]["old"][:warm][:total] }
    result = {summary: summary, reductions_percent: reductions, paired_warm_percent: distribution(paired), appearances: appearances,
              appearance_gate: appearances.all? { |entry| entry[:matches].values.all? },
              warm_target_gate: reductions[:warm] >= 10, concurrency: 1, instrumentation: "identical test-only observer; monotonic milliseconds; summed conversion phases"}
    File.write(File.join(directory, "benchmark.json"), JSON.pretty_generate(result))
    puts JSON.generate(result)
  end
end

if $PROGRAM_NAME == __FILE__
  abort "Readiness fixture disabled" unless ENV["PARADEM_PDF_READINESS_BROWSER"] == "1"
  ReadinessBenchmark.run(ARGV.fetch(1)) if ARGV.first == "--benchmark"
end
