import express from 'express';
import dotenv from 'dotenv';

dotenv.config({ path: '../.env' });

const app = express();
const port = 3001;
app.use(express.json());

app.get('/api/health', (_req, res) => res.json({ success: true, server: 'Discord OAuth' }));

app.post('/api/token', async (req, res) => {
  try {
    const code = req.body?.code;
    const clientId = process.env.VITE_DISCORD_CLIENT_ID;
    const clientSecret = process.env.DISCORD_CLIENT_SECRET;

    if (!code) return res.status(400).json({ success: false, error: 'No Discord authorization code was supplied.' });
    if (!clientId) return res.status(500).json({ success: false, error: 'VITE_DISCORD_CLIENT_ID is missing from .env.' });
    if (!clientSecret) return res.status(500).json({ success: false, error: 'DISCORD_CLIENT_SECRET is missing from .env.' });

    const response = await fetch('https://discord.com/api/oauth2/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: clientId,
        client_secret: clientSecret,
        grant_type: 'authorization_code',
        code,
      }),
    });

    const text = await response.text();
    let data;
    try { data = JSON.parse(text); } catch { data = { error: 'invalid_json', error_description: text }; }

    if (!response.ok) {
      console.error('Discord OAuth error:', response.status, data.error, data.error_description);
      return res.status(response.status).json({
        success: false,
        error: data.error || 'discord_oauth_error',
        error_description: data.error_description || 'Discord rejected the OAuth token exchange.',
      });
    }

    if (!data.access_token) return res.status(502).json({ success: false, error: 'Discord returned no access token.' });
    return res.json({ access_token: data.access_token });
  } catch (error) {
    console.error(error);
    return res.status(500).json({ success: false, error: error.message });
  }
});

app.listen(port, () => console.log(`Discord OAuth server listening at http://localhost:${port}`));
