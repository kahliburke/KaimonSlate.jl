<script setup lang="ts">
// Inline SVG so the hero banner never depends on an external asset path
// (the small logo is committed; the big demo GIFs come from the Release).
</script>

<template>
  <div class="logo-banner">
    <svg class="mark" viewBox="0 0 48 48" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
      <rect x="2.5" y="2.5" width="43" height="43" rx="12" fill="#141828" stroke="#2a2e40" stroke-width="1.5" />
      <path d="M16 15 L33 20 M33 20 L22 34 M16 15 L22 34" stroke="#566089" stroke-width="2" stroke-linecap="round" />
      <circle cx="16" cy="15" r="4" fill="#7cc0ff" />
      <circle cx="33" cy="20" r="4" fill="#c586c0" />
      <circle cx="22" cy="34" r="4" fill="#56d364" />
    </svg>
  </div>
</template>

<style scoped>
.logo-banner {
  display: flex;
  justify-content: center;
  padding: 2.5rem 0 0;
}
.mark {
  width: 120px;
  height: 120px;
  filter: drop-shadow(0 4px 18px rgba(86, 156, 214, 0.3));
}
</style>
