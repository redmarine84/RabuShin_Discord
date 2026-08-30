import { defineConfig } from 'vite';

// https://vitejs.dev/config/
export default defineConfig({
    envDir: '../',

    server: {

        allowedHosts: [
            'americas-employers-cakes-neural.trycloudflare.com'
        ],

        proxy: {

            // Discord starter server
            '/api': {
                target: 'http://localhost:3001',
                changeOrigin: true,
                secure: false,
                ws: true,
            },

            // RabuShin ASP.NET/VB.NET server
            '/game-api': {
                target: 'http://localhost:3002',
                changeOrigin: true,
                secure: false,
                ws: true,
            },

        },

        hmr: {
            clientPort: 443,
        },

    },
});