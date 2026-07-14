import type MarkdownIt from 'markdown-it'
import type Token from 'markdown-it/lib/token'
import { defineConfig } from 'vitepress'
import { tabsMarkdownPlugin } from 'vitepress-plugin-tabs'
import { withMermaid } from 'vitepress-plugin-mermaid'

const BASE = '/KaimonSlate.jl/'
// In CI, KAIMONSLATE_ASSET_BASE points to the docs-assets GitHub Release (where the
// generated demo GIFs/MP4s live). Locally, it falls back to VitePress public/assets/
// served under the site base. The committed logo is always served locally (see below).
const ASSET_BASE = process.env.KAIMONSLATE_ASSET_BASE ?? (BASE + 'assets/')

// The logo is small + committed (src/public/assets/slate-logo.svg), so it is ALWAYS
// served locally — never from the Release. `themeConfig.logo` runs through VitePress's
// withBase(), which prepends BASE to a root-relative path, so a BASE-relative path
// ('assets/...') is correct (withBase adds BASE exactly once).
const LOGO_SRC = 'assets/slate-logo.svg'

// Rewrite any `assets/<name>.{png,jpg,gif,webm,mp4}` reference to ASSET_BASE via a Vue `:src`
// binding (a runtime expression, so VitePress doesn't try to ESM-resolve the path during SSR and
// the Release URL works in CI). Generated demo media (screenshots + clips) live under the
// docs-assets Release in CI, or public/assets/ locally — never in the repo. webm/mp4 become an
// autoplaying, looping, muted `<video>` (a silent screencast); images become `<img>`.
// Native UI widths (CSS px) of panel/dialog shots → display each at its real width so the captured
// 2x screenshots render at a CONSISTENT font size instead of being fit-scaled to the column by
// different amounts. Keyed by filename (Documenter strips any `#w=` fragment before we see the src).
const SHOT_WIDTHS: Record<string, number> = {
  'agent-panel.png': 380, 'packages-panel.png': 480, 'history-panel.png': 420,
  'controls-palette.png': 300, 'command-palette.png': 560, 'export-dialog.png': 520,
  'settings.png': 520, 'publish-panel.png': 480,
}
function slateAssetsPlugin(md: MarkdownIt, assetBase: string) {
  md.renderer.rules.image = function (
    tokens: Token[],
    idx: number,
    options: object,
    env: object,
    self: MarkdownIt['renderer'],
  ) {
    const token = tokens[idx]
    const srcIdx = token.attrIndex('src')
    if (srcIdx >= 0) {
      const src = token.attrs![srcIdx][1]
      const m = src.match(/(?:\/|\.\.?\/)?assets\/([\w.\-]+\.(png|jpe?g|gif|webm|mp4))$/)
      if (m) {
        const alt = token.attrGet('alt') || ''
        const url = `${assetBase}${m[1]}`
        if (m[2] === 'webm' || m[2] === 'mp4') {
          return `<video :src="'${url}'" class="slate-clip" autoplay loop muted playsinline controls aria-label="${alt}"></video>\n`
        }
        const w = SHOT_WIDTHS[m[1]]
        const style = w ? ` style="width:${w}px;max-width:100%"` : ''
        return `<img class="slate-shot" :src="'${url}'" alt="${alt}"${style} />\n`
      }
    }
    return self.renderToken(tokens, idx, options)
  }
}

export default withMermaid(defineConfig({
  base: BASE,
  title: 'KaimonSlate.jl',
  description: 'Reactive Julia notebooks — live, in the browser, agent-assisted',
  lastUpdated: true,
  cleanUrls: true,
  head: [['link', { rel: 'icon', href: BASE + 'assets/slate-logo.svg' }]],

  vite: {
    define: {
      // Injected into Vue components (e.g. LogoBanner.vue)
      __ASSET_BASE__: JSON.stringify(ASSET_BASE),
    },
    vue: {
      template: {
        transformAssetUrls: {
          includeAbsolute: false,
        },
      },
    },
    build: {
      rollupOptions: {
        external: [/^\/assets\//, /^\/KaimonSlate\.jl\/assets\//],
      },
    },
  },

  markdown: {
    config(md) {
      md.use(tabsMarkdownPlugin)
      md.use((m: MarkdownIt) => slateAssetsPlugin(m, ASSET_BASE))
    },
  },

  mermaid: {},

  themeConfig: {
    logo: LOGO_SRC,
    nav: [
      { text: 'Guide', link: '/getting-started' },
      { text: 'The Agent', link: '/agent' },
      { text: 'API', link: '/api' },
    ],

    sidebar: [
      {
        text: 'Introduction',
        items: [
          { text: 'Installation', link: '/installation' },
          { text: 'Getting Started', link: '/getting-started' },
          { text: 'Architecture', link: '/architecture' },
        ],
      },
      {
        text: 'Guide',
        items: [
          { text: 'Notebook Basics', link: '/notebook-basics' },
          { text: 'Cell Tags & Caching', link: '/cell-tags' },
          { text: 'Memoization & Caching', link: '/memoization' },
          { text: 'Command Palette & Help', link: '/palette-and-help' },
          { text: 'Reactive Cells', link: '/reactivity' },
          { text: 'The Dependency Graph', link: '/dag' },
          { text: 'Live Updates', link: '/live-updates' },
          { text: 'Widgets & @bind', link: '/widgets' },
          { text: 'Charts', link: '/visualization' },
          { text: 'Tables', link: '/tables' },
          { text: 'Animation', link: '/animation' },
          { text: 'Documents & Citations', link: '/documents' },
          { text: 'Slides & Present', link: '/slides' },
          { text: 'The AI Agent', link: '/agent' },
          { text: 'Timeline', link: '/history' },
          { text: 'Export', link: '/export' },
          { text: 'Publishing', link: '/publishing' },
          { text: 'Packages', link: '/packages' },
          { text: 'Configuration', link: '/configuration' },
          { text: 'Remotes', link: '/remotes' },
          { text: 'Regions', link: '/regions' },
        ],
      },
      {
        text: 'Reference',
        items: [
          { text: 'API Reference', link: '/api' },
        ],
      },
    ],

    outline: {
      level: [2, 3],
    },

    search: {
      provider: 'local',
    },
    socialLinks: [
      { icon: 'github', link: 'https://github.com/kahliburke/KaimonSlate.jl' },
    ],
    footer: {
      message: 'Made with <a href="https://documenter.juliadocs.org/stable/">Documenter.jl</a> and <a href="https://vitepress.dev">VitePress</a>',
      copyright: 'Copyright © 2025-present',
    },
  },
}))
