#!/usr/bin/env node
// precss 性能基准：共同支持语法子集上的批量编译吞吐量。
//
// 对比对象：
//   - precss native CLI：一次启动 CLI，通过 NUL 分隔输入批量编译
//   - Dart Sass JS：Node.js `sass` 包的 compileString API，在同一 Node 进程内循环
//   - less.js：Node.js `less` 包，在同一 Node 进程内循环
//
// 数据集由 example/perf/datasets/manifest.json 描述，并按固定 seed 确定性生成。
// 每份输入先做归一化正确性校验，只有双方输出一致的数据才计入性能结果。
// 资源测量是独立阶段，目前在 Linux 上记录 precss native CLI 的峰值 RSS。
//
// 用法：
//   node example/perf/bench.mjs --profile quick
//   node example/perf/bench.mjs --profile release --iterations 5 --warmup 1 --json result.json
//   node example/perf/bench.mjs [份数] [嵌套深度] [seed]  # 兼容旧用法
import { compileString } from 'sass'
import less from 'less'
import { execFileSync, spawn } from 'node:child_process'
import { cpus, platform, release, tmpdir, totalmem } from 'node:os'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const root = new URL('../..', import.meta.url).pathname
const CLI = process.env.PRECSS_CLI || join(root, '_build/native/debug/build/cmd/cli/cli.exe')
const manifestPath = join(root, 'example/perf/datasets/manifest.json')
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
const knownValueFlags = new Set(['--profile', '--count', '--depth', '--seed', '--iterations', '--warmup', '--json'])

function parseArgs() {
  const values = {}
  const positionals = []
  for (let i = 2; i < process.argv.length; i++) {
    const arg = process.argv[i]
    if (arg.startsWith('--')) {
      if (knownValueFlags.has(arg)) values[arg] = process.argv[++i]
      else values[arg] = true
    } else {
      positionals.push(arg)
    }
  }
  return { values, positionals }
}
const { values: args, positionals } = parseArgs()
const profileName = args['--profile'] || 'quick'
const profile = manifest.profiles[profileName]
if (!profile) throw new Error(`unknown benchmark profile: ${profileName}`)
const N = Number(args['--count'] ?? (args['--profile'] ? profile.count : positionals[0] || profile.count))
const DEPTH = Number(args['--depth'] ?? (args['--profile'] ? profile.depth : positionals[1] || profile.depth))
const SEED = Number(args['--seed'] ?? (args['--profile'] ? profile.seed : positionals[2] || profile.seed))
const ITERATIONS = Number(args['--iterations'] ?? profile.iterations)
const WARMUP = Number(args['--warmup'] ?? profile.warmup)
const targetInputBytes = Number(profile.target_input_bytes || 0)
const jsonPath = args['--json'] || null

if (!Number.isInteger(N) || N < 1 || !Number.isInteger(DEPTH) || DEPTH < 0 ||
    !Number.isInteger(SEED) || !Number.isInteger(ITERATIONS) || ITERATIONS < 1 ||
    !Number.isInteger(WARMUP) || WARMUP < 0) {
  throw new Error('invalid benchmark options')
}

function rng(seed) {
  let s = seed >>> 0
  return () => {
    s ^= s << 13
    s ^= s >>> 17
    s >>>= 0
    return s / 4294967296
  }
}
const pick = (r, arr) => arr[Math.floor(r() * arr.length)]
const id = (r, p) => p + Math.floor(r() * 999)

const COLORS = ['red', 'blue', 'green', '#1a2b3c', 'rgb(10,20,30)', 'rebeccapurple']
const PROPS = ['color', 'background', 'margin', 'padding', 'width', 'height', 'font-size', 'border']
const SELS = ['.card', '.btn', '.grid', '#main', '.wrapper', 'div', '.tag-item']
const UNITS = ['px', 'em', 'rem', '%']
const val = (r) => `${pick(r, [10, 12, 16, 24, 32, 48, 64])}${pick(r, UNITS)}`
const prop = (r) => pick(r, PROPS)
const sel = (r) => `${pick(r, SELS)}-${id(r, 'x')}`
const varName = (r) => `${pick(r, ['c', 'g', 'w', 'm'])}${id(r, '')}`

function genTree(r, level, depth) {
  const node = { sel: sel(r), decls: [], varName: null, varVal: null, children: [] }
  const nd = 1 + Math.floor(r() * 3)
  for (let i = 0; i < nd; i++) node.decls.push(`${prop(r)}: ${val(r)}`)
  if (r() < 0.45) {
    node.varName = varName(r)
    node.varVal = pick(r, COLORS)
  }
  if (level < depth) {
    const nc = 1 + Math.floor(r() * 2)
    for (let i = 0; i < nc; i++) node.children.push(genTree(r, level + 1, depth))
  }
  return node
}
function emitScss(n, ind) {
  let out = `${ind}${n.sel} {\n`
  if (n.varName) out += `${ind}  $${n.varName}: ${n.varVal};\n`
  for (const d of n.decls) out += `${ind}  ${d};\n`
  for (const c of n.children) out += emitScss(c, ind + '  ')
  return out + `${ind}}\n`
}
function emitSass(n, ind) {
  let out = `${ind}${n.sel}\n`
  if (n.varName) out += `${ind}  $${n.varName}: ${n.varVal}\n`
  for (const d of n.decls) out += `${ind}  ${d}\n`
  for (const c of n.children) out += emitSass(c, ind + '  ')
  return out
}
function emitLess(n, ind) {
  let out = `${ind}${n.sel} {\n`
  if (n.varName) out += `${ind}  @${n.varName}: ${n.varVal};\n`
  for (const d of n.decls) out += `${ind}  ${d};\n`
  for (const c of n.children) out += emitLess(c, ind + '  ')
  return out + `${ind}}\n`
}
function inflate(source, targetBytes) {
  if (!targetBytes || Buffer.byteLength(source) >= targetBytes) return source
  let out = source
  while (Buffer.byteLength(out) < targetBytes) out += source
  return out
}
function makeDataset() {
  const scssList = []
  const sassList = []
  const lessList = []
  const perFileTarget = targetInputBytes ? Math.ceil(targetInputBytes / N) : 0
  for (let i = 0; i < N; i++) {
    const r = rng(SEED + i * 7919)
    let scss = ''
    let sass = ''
    let less = ''
    const tops = 1 + Math.floor(r() * 3)
    for (let t = 0; t < tops; t++) {
      const tree = genTree(r, 0, DEPTH)
      scss += emitScss(tree, '')
      sass += emitSass(tree, '')
      less += emitLess(tree, '')
    }
    scssList.push(inflate(scss, perFileTarget))
    sassList.push(inflate(sass, perFileTarget))
    lessList.push(inflate(less, perFileTarget))
  }
  return { scssList, sassList, lessList }
}

const { scssList, sassList, lessList } = makeDataset()
const bytes = (list) => list.reduce((n, x) => n + Buffer.byteLength(x), 0)
const norm = (css) => css.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\s+/g, ' ').trim()
const now = (f) => {
  const t = process.hrtime.bigint()
  const value = f()
  return { ms: Number(process.hrtime.bigint() - t) / 1e6, value }
}
function median(xs) {
  const a = [...xs].sort((x, y) => x - y)
  const m = Math.floor(a.length / 2)
  return a.length % 2 ? a[m] : (a[m - 1] + a[m]) / 2
}
function percentile(xs, p) {
  const a = [...xs].sort((x, y) => x - y)
  return a[Math.min(a.length - 1, Math.ceil(a.length * p) - 1)]
}
function stats(samples) {
  return {
    min_ms: Number(Math.min(...samples).toFixed(3)),
    median_ms: Number(median(samples).toFixed(3)),
    p95_ms: Number(percentile(samples, 0.95).toFixed(3)),
    max_ms: Number(Math.max(...samples).toFixed(3)),
    samples: samples.map((x) => Number(x.toFixed(3))),
  }
}
function moonOnce(payload, sub) {
  const r = now(() => execFileSync(CLI, [sub], {
    input: payload,
    maxBuffer: 1 << 28,
  }).toString())
  return { ms: r.ms, parts: r.value.split('\u0000') }
}
function moonLibraryOnce(payload, flags) {
  const raw = execFileSync(CLI, ['bench-library', ...flags], {
    input: payload,
    maxBuffer: 1 << 28,
  }).toString().trim()
  const line = raw.split('\n').find((x) => x.startsWith('BENCH_LIBRARY_JSON:'))
  if (!line) throw new Error(`invalid bench-library output: ${raw}`)
  return JSON.parse(line.slice('BENCH_LIBRARY_JSON:'.length))
}
function dartOnce(list, syntax = 'scss') {
  const r = now(() => list.map((s) => compileString(s, { style: 'expanded', syntax }).css))
  return { ms: r.ms, parts: r.value }
}
async function lessOnce(list) {
  const t = process.hrtime.bigint()
  const parts = []
  for (const s of list) parts.push((await less.render(s)).css)
  return { ms: Number(process.hrtime.bigint() - t) / 1e6, parts }
}
async function sample(moonList, sub, libraryFlags, official, officialArgs) {
  const payload = moonList.join('\u0000')
  let firstMoon = null
  let firstOfficial = null
  for (let i = 0; i < WARMUP; i++) {
    moonOnce(payload, sub)
    await official(officialArgs)
  }
  const moonSamples = []
  const librarySamples = []
  const officialSamples = []
  for (let i = 0; i < ITERATIONS; i++) {
    const m = moonOnce(payload, sub)
    const l = moonLibraryOnce(payload, libraryFlags)
    const o = await official(officialArgs)
    if (!firstMoon) firstMoon = m
    if (!firstOfficial) firstOfficial = o
    moonSamples.push(m.ms)
    librarySamples.push(l.elapsed_us / 1000)
    officialSamples.push(o.ms)
  }
  return {
    moon: stats(moonSamples),
    library: stats(librarySamples),
    official: stats(officialSamples),
    moonParts: firstMoon.parts,
    officialParts: firstOfficial.parts,
    payload,
  }
}
function verify(mParts, oParts) {
  let pass = 0
  for (let k = 0; k < Math.min(mParts.length, oParts.length); k++) {
    if (mParts[k] !== undefined && oParts[k] !== undefined && norm(mParts[k]) === norm(oParts[k])) pass++
  }
  return pass
}
function versionOf(pkg) {
  try { return JSON.parse(readFileSync(join(root, 'node_modules', pkg, 'package.json'))).version } catch { return 'unknown' }
}
function commandOutput(command, args) {
  try { return execFileSync(command, args, { cwd: root }).toString().trim() } catch { return 'unknown' }
}
async function measurePeakRss(payload, sub) {
  if (platform() !== 'linux') return null
  const child = spawn(CLI, [sub], { cwd: root })
  let output = ''
  let peak = 0
  child.stdout.on('data', (chunk) => { output += chunk.toString() })
  child.stderr.on('data', () => {})
  const sample = () => {
    try {
      const status = readFileSync(`/proc/${child.pid}/status`, 'utf8')
      const match = status.match(/^VmHWM:\s+(\d+)\s+kB$/m) || status.match(/^VmRSS:\s+(\d+)\s+kB$/m)
      if (match) peak = Math.max(peak, Number(match[1]))
    } catch {}
  }
  // 先在 stdin 关闭前采样一次，避免极短任务在第一轮定时器前已经退出。
  sample()
  const timer = setInterval(sample, 1)
  child.stdin.end(payload)
  const exitCode = await new Promise((resolve) => child.on('close', resolve))
  clearInterval(timer)
  sample()
  if (exitCode !== 0 || peak <= 0) return null
  // Linux VmHWM is the process high-water RSS and is independent of benchmark timing.
  return { peak_rss_bytes: peak * 1024, peak_rss_kib: peak, measurement: 'Linux /proc VmHWM peak RSS', available: true }
}

async function main() {
  const runs = []
  const resources = []
  const scss = await sample(scssList, 'compile', ['--scss'], (xs) => Promise.resolve(dartOnce(xs)), scssList)
  const sass = await sample(sassList, 'compile', ['--sass'], (xs) => Promise.resolve(dartOnce(xs, 'indented')), sassList)
  const lessRun = await sample(lessList, 'compile-less', ['--less'], lessOnce, lessList)
  const add = async (name, r, baseline, inputList) => {
    const matched = verify(r.moonParts, r.officialParts)
    const valid = matched === N
    const speedup = valid ? Number((r.official.median_ms / r.moon.median_ms).toFixed(3)) : null
    runs.push({
      syntax: name,
      input_bytes: bytes(inputList),
      output_bytes: bytes(r.moonParts),
      precss_native_cli: r.moon,
      precss_library: r.library,
      baseline: { ...baseline, stats: r.official },
      speedup_x: speedup,
      library_speedup_x: valid ? Number((r.official.median_ms / r.library.median_ms).toFixed(3)) : null,
      correctness: { matched, total: N, included: valid },
    })
    resources.push({
      syntax: name,
      runner: 'precss native CLI',
      ...(await measurePeakRss(r.payload, name === 'less' ? 'compile-less' : 'compile') || {
        peak_rss_bytes: null,
        peak_rss_kib: null,
        measurement: 'unavailable on this platform',
        available: false,
      }),
    })
  }
  await add('scss', scss, { name: 'Dart Sass JS API', package: 'sass', api: 'compileString' }, scssList)
  await add('sass', sass, { name: 'Dart Sass JS API', package: 'sass', api: 'compileString', syntax: 'indented' }, sassList)
  await add('less', lessRun, { name: 'less.js', package: 'less', api: 'render' }, lessList)

  const result = {
    schema: 2,
    project: 'conglinyizhi/precss',
    generated_at: new Date().toISOString(),
    commit: commandOutput('git', ['rev-parse', 'HEAD']),
    profile: profileName,
    dataset: {
      name: profile.name,
      count: N,
      depth: DEPTH,
      seed: SEED,
      target_input_bytes: targetInputBytes,
      actual_input_bytes: {
        scss: bytes(scssList),
        sass: bytes(sassList),
        less: bytes(lessList),
      },
      iterations: ITERATIONS,
      warmup: WARMUP,
    },
    benchmark: {
      name: profile.name,
      count: N,
      depth: DEPTH,
      seed: SEED,
      iterations: ITERATIONS,
      warmup: WARMUP,
      input_bytes: bytes(scssList),
      output_bytes: bytes(scss.moonParts),
      measurement: 'CLI wall-clock includes one native process and stdin/stdout; precss_library measures compile stage inside one native process; JS baselines reuse the Node process',
    },
    environment: {
      node_js: process.version,
      sass_npm: versionOf('sass'),
      less_js: versionOf('less'),
      moonbit: commandOutput('moon', ['version']).split('\n')[0],
      os: `${platform()} ${release()}`,
      cpu: cpus()[0]?.model || 'unknown',
      logical_cpus: cpus().length,
      memory_gb: Number((totalmem() / 1024 ** 3).toFixed(1)),
    },
    notes: [
      '输入由 manifest 描述的固定 seed 确定性生成，三种语法逻辑等价',
      '仅在双方输出归一化后一致时计入性能结果',
      'Dart Sass 对比项是 sass npm 包的 JavaScript API，不是 Dart Sass 原生 CLI',
      'precss 的 SASS 入口先把缩进语法规范化成等价 SCSS 再进同一条管线，数字含这段转换开销',
      'memory.resources 是独立资源测量，不计入性能耗时；目前仅 Linux 提供峰值 RSS',
    ],
    results: runs,
    resources,
  }

  // 修正每种语法的实际输出大小；benchmark 字段保留向后兼容的 SCSS 聚合值。
  result.benchmark.output_bytes = runs[0].output_bytes
  const pad = (n) => String(n).padStart(10)
  console.log(`\n===== precss 性能基准（profile=${profileName} 份数=${N} 深度=${DEPTH} seed=${SEED} iterations=${ITERATIONS} warmup=${WARMUP}）=====`)
  console.log(`${'格式'.padEnd(6)} ${'CLI(ms)'.padStart(12)} ${'库(ms)'.padStart(12)} ${'对比(ms)'.padStart(12)} ${'speedup'.padStart(10)} ${'正确性'.padStart(10)}`)
  console.log('------------------------------------------------------------------')
  for (const r of runs) {
    const speed = r.library_speedup_x === null ? '-' : `${r.library_speedup_x}x`
    console.log(`${r.syntax.padEnd(6)} ${pad(r.precss_native_cli.median_ms)} ${pad(r.precss_library.median_ms)} ${pad(r.baseline.stats.median_ms)} ${speed.padStart(10)} ${`${r.correctness.matched}/${r.correctness.total}`.padStart(10)}`)
  }
  console.log('------------------------------------------------------------------')
  console.log('(library_speedup_x > 1 表示 precss 库编译阶段更快；CLI wall-clock 仍保存在 precss_native_cli；只有 correctness.included=true 的结果才应作为性能结论)')

  if (jsonPath) {
    const outputPath = jsonPath.startsWith('/') ? jsonPath : join(root, jsonPath)
    mkdirSync(join(outputPath, '..'), { recursive: true })
    writeFileSync(outputPath, JSON.stringify(result, null, 2) + '\n')
    console.log(`JSON: ${outputPath}`)
  }
  if (runs.some((r) => !r.correctness.included)) process.exitCode = 1
}

main()
