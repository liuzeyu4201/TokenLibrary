# Native resource sampling and a real-body mixed library

These tools prepare isolated data and read process statistics. They do not launch,
drive, install, replace or terminate an app, contact a server, or read credentials.

## Mixed fixture

`../fixtures/generate_mixed_performance_fixture.swift` uses the real `DocumentStore`
and default PDFKit text extractor. It refuses an existing output directory and
non-temporary locations. Input files are the existing synthetic `research-three-pages.pdf`,
`large-near-50mb.pdf`, and `fixture-diagram.png`.

The generated offline library contains 1,000 documents, plus 10 folders and 4 topics:

- 800 Markdown notes: 700 short, 100 long; 100 contain a chart, Mermaid and LaTeX.
- 199 separately stored three-page PDFs using the same synthetic text template.
- One real 49,745,911-byte eight-page PDF. No padding or fake PDF metadata.
- Real text indexes, 605 PDF pages, 201 media records, no pending operation or server binding.

The identical three-page template is intentional and disclosed. This is not 200
different research papers, scanned-PDF OCR, or a representative personal corpus.

After building the local Core Debug package, the following links its existing
static artifact without running another Core test suite:

```sh
swiftc -parse-as-library tests/fixtures/generate_mixed_performance_fixture.swift \
  -I clients/LibraryCore/.build/out/Products/Debug \
  -I clients/LibraryCore/.build/checkouts/GRDB.swift/Sources/GRDBSQLite \
  -I clients/LibraryCore/.build/checkouts/swift-cmark/src/include \
  -I clients/LibraryCore/.build/checkouts/swift-cmark/extensions/include \
  -I clients/LibraryCore/.build/checkouts/swift-markdown/Sources/CAtomic/include \
  -L clients/LibraryCore/.build/out/Products/Debug -lLibraryCore -lsqlite3 \
  -o /tmp/tokenlibrary-generate-mixed-performance-fixture

nice -n 10 /usr/bin/time -l /tmp/tokenlibrary-generate-mixed-performance-fixture \
  /tmp/TokenLibrary-Mixed1000-NewRun /tmp/tokenlibrary-ui-fixtures
```

Choose a **new** directory for every generation. `performance-manifest.json`
contains source-media hashes, identities for the long note and large PDF, all raw
timings, expected hit counts and database hash. Construction timings include
real first indexing. Query timings use the finished index and warmed process;
they are SDK results, not native interaction results.

The prepared fixture is `/tmp/tokenlibrary-ui-fixtures/TokenLibrary-Mixed1000-20260927`.
For a later authorized Mac native run, copy a verification App to a separate path,
use its own `app.tokenlibrary.verification.performance` ID, set Debug Info key
`TokenLibraryVerificationDirectory` to this fixture, and sign that copy. Do not
replace an active verification App or point a production bundle at this directory.
An independently signed Mac copy was subsequently prepared at
`/private/tmp/tokenlibrary-performance-app-tgdh8opa/TokenLibraryPerformanceVerification.app`,
with this Info directory and display name `TokenLibrary 千项验收`. Its
`verification.json` is beside the App; ad hoc deep/strict signing passed and the
source package/fixture remained unchanged. Preparation did not launch the App.
For iOS, use a separate
validation installation/container with an explicitly selected fixture directory;
do not overwrite the existing sync-test container. Copying the complete offline
fixture tests opening an indexed library, not first sync or first import indexing.

The subsequent iOS preparation uses bundle
`app.tokenlibrary.verification.performance.ios` and its **own** default
`Library/Application Support/TokenLibrary` directory. The App is built with an
Xcode bundle override so simulator entitlements match, then installed without
launching. A fresh generator output is copied; the Mac fixture's later reading
queue is not inherited. Details and exact container identity are in
`/private/tmp/tokenlibrary-ios-performance-build-hblkujsg/verification.json`.

Before and after the GUI operator's first launch, verify paths and content using:

```sh
nice -n 10 python3 tests/performance/prove_ios_mixed_fixture.py \
  --preparation /private/tmp/tokenlibrary-ios-performance-build-hblkujsg/verification.json \
  --phase actual-observed-phase \
  --output /tmp/tokenlibrary-ios-mixed-new-proof.json
```

This script only accepts the dedicated performance bundle, compares simctl's
container identity to the preparation manifest, opens SQLite in a read-only
transaction, and hashes the 201 media. It never launches the App or reads a
session. Run outside the resource measurement window, since media hashing itself
adds I/O. Before first launch, the copied PDF absolute paths still refer to the
generated source; after native opening, all 200 should refer to the new container
without revision changes. The report records path count, document-field changes,
reading fields and queue operations explicitly; a prepared copy is not a UI pass.

## CPU and resident-memory sampler

Pass the PID and **exact executable path observed for the intended verification
process**. The sampler checks its bundle ID, executable and process start time;
it refuses a production bundle and stops if the PID exits or changes identity.
It does not discover or guess a process, attach a debugger, take screenshots or
send input.

```sh
python3 tests/performance/sample_native_process.py sample \
  --pid <observed-verification-pid> \
  --executable '/exact/Verification.app/Contents/MacOS/TokenLibrary' \
  --output /tmp/tokenlibrary-native-perf-new-run \
  --duration 180 --interval 1
```

Use the iOS Simulator executable path rather than `Contents/MacOS/...` when
sampling a simulator process. `manifest.json` records the executable hash and
identity. `samples.jsonl` preserves monotonic time, cumulative process CPU time,
RSS and inspection cost. CPU percentage is the delta in CPU time divided by
elapsed monotonic time; it can exceed 100% when multiple cores are busy.

The GUI operator can label a phase using another shell invocation; the command
only appends a record to the sampler output:

```sh
python3 tests/performance/sample_native_process.py mark \
  --output /tmp/tokenlibrary-native-perf-new-run \
  --label catalog-search-pdf --event begin
```

Use `end` or `checkpoint` as appropriate. Markers can be aligned with tool and
native observations, but **a manual begin/end interval is not exact UI latency**.
CUA round-trip time includes transport, accessibility-tree and screenshot work.
Separate marker processes can have a different monotonic epoch in the execution
environment. Phase alignment therefore uses their shared wall-clock timestamps;
CPU deltas use the sampler's own monotonic clock. Raw timestamps are preserved.
Rebuild a report during or after capture without changing the raw files:

```sh
python3 tests/performance/sample_native_process.py report \
  --output /tmp/tokenlibrary-native-perf-new-run
```

`report.json` includes per-phase resource distributions. It excludes the first CPU
interval of each phase because that interval can straddle the preceding phase.
Unclosed phases are explicitly marked, and partial JSONL lines are counted.
The report is separate from `summary.json`, so a capture started with an earlier
analysis implementation remains auditable.

Minimum useful native phases, each with the same fixture and build identity:

1. Record 15–20 seconds of idle after launch; distinguish first launch and reopening.
2. Open the personal catalog, confirm 1,000 documents, scroll several screens.
3. Search `Research Anchor Beta` (199), `MixedCorpusNeedle` (800),
   `Large PDF Anchor 7` (1), `NoteTailMarker00799` (1), and `AbsentMixedCorpusNeedle` (0).
   Confirm counts and clear each query; label sparse and dense searches separately.
4. Open the long note and the eight-page large PDF, perform a page search and return.
5. Record another idle period to observe whether CPU settles and resident memory persists.

For p95 of actual GUI response or scroll frame time, add a separately approved
native event/frame measurement method and repeated actions. This sampler does
not infer either number. RSS is sampled resident memory, not a guaranteed peak or
physical footprint. WebKit child processes and WindowServer are excluded;
simulator results cannot be presented as physical-iPhone measurements. First
network sync, initial import, memory pressure and background limits remain
separate experiments.

## Tool verification

```sh
python3 -m unittest discover -s tests/performance -p 'test_*.py' -v
```

Eight tests cover CPU clock formats, Darwin field parsing including spaces,
validation-bundle restrictions, reading the test's own non-GUI process, and the
resource-summary/marker boundary, cross-process clock alignment, per-phase CPU
interval boundaries, and partial JSONL handling. They do not claim a product UI pass.
