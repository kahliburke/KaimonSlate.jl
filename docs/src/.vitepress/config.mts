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

// Rewrite ./assets/slate_*.{gif,mp4,webm} to use ASSET_BASE via Vue's :src binding.
// Using :src makes it a runtime expression so VitePress doesn't try to resolve the
// path as an ESM import during SSR (and so the Release URL works in CI).
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
      const m = src.match(/(?:\.\.?\/)?assets\/(slate_[^"')]+\.(?:gif|mp4|webm))$/)
      if (m) {
        const alt = token.attrGet('alt') || ''
        return `<img :src="'${assetBase}${m[1]}'" alt="${alt}" />\n`
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
          { text: 'Reactive Cells', link: '/reactivity' },
          { text: 'Widgets & @bind', link: '/widgets' },
          { text: 'The AI Agent', link: '/agent' },
          { text: 'Time Machine', link: '/history' },
          { text: 'Export', link: '/export' },
          { text: 'Packages', link: '/packages' },
          { text: 'Configuration', link: '/configuration' },
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
