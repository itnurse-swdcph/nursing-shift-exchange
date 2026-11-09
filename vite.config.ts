import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  // GitHub Pages needs a repository subpath; Vercel serves this app from the domain root.
  base: process.env.VERCEL ? '/' : '/nursing-shift-exchange/',
  plugins: [react()],
})
