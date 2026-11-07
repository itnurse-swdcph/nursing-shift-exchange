import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  // Repository project site: https://itnurse-swdcph.github.io/nursing-shift-exchange/
  base: '/nursing-shift-exchange/',
  plugins: [react()],
})
