#!/usr/bin/env node
// 把 CodeMirror 5 从 node_modules 拷进 site/static/codemirror/（不入库）。
//
// 这份之前是手工 vendored 进仓库的（4 个文件 453 KB，占入库内容一半以上），
// 改成本地从 npm 取：仓库只留 devDependency，站点构建前跑一次本脚本。
// site/static/codemirror/ 已在 .gitignore 里；SSG 复制到 out/ 的路径不变。
import { copyFileSync, existsSync, mkdirSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'

const root = resolve(import.meta.dirname, '..')
const vendor = join(root, 'node_modules', 'codemirror')
const target = join(root, 'site', 'static', 'codemirror')

// SSG 与页面依赖的四个文件，路径与 codemirror@5 包布局一一对应
const FILES = [
  'lib/codemirror.js',
  'lib/codemirror.css',
  'mode/css/css.js',
  'theme/dracula.css',
]

if (!existsSync(vendor)) {
  console.error('[vendor:codemirror] 找不到 node_modules/codemirror —— 先跑 pnpm install')
  process.exit(1)
}

for (const rel of FILES) {
  const from = join(vendor, rel)
  if (!existsSync(from)) {
    console.error(`[vendor:codemirror] codemirror 包里没有 ${rel}（包布局变了？）`)
    process.exit(1)
  }
  const to = join(target, rel)
  mkdirSync(dirname(to), { recursive: true })
  copyFileSync(from, to)
}

console.log(`[vendor:codemirror] ${FILES.length} 个文件 -> site/static/codemirror/`)
