# Auday request logger (Cloudflare Worker)

A research proxy for the real Auday app: it forwards each AI request unchanged to Gemini and logs the request and reply on Cloudflare. Not needed to run Auday Replica. The API key is passed through, never stored; logs are readable only with the admin token and deleted after 60 days.

## What you need

- **Node.js 22 or newer**: download the LTS installer from [nodejs.org](https://nodejs.org/) and install it; `node --version` should print `v22` or higher.
- **A Cloudflare account**: sign up for free at [dash.cloudflare.com](https://dash.cloudflare.com/sign-up).
- The Gemini API key you use in the Auday app.

## Install and deploy

Run the commands in the `auday-replica/cloud/capture-worker` folder.

1. Install the dependencies:

   ```bash
   npm ci
   ```

2. Sign in to Cloudflare. A browser window opens; click Allow:

   ```bash
   npx wrangler login
   ```

3. Deploy. The first deploy creates a KV store named `LOGS` in your account; if asked, choose to create it. At the end it prints an address like `https://auday-capture.<your-subdomain>.workers.dev`. Write it down:

   ```bash
   npx wrangler deploy
   ```

4. Create and store two random tokens (write them down):

   ```bash
   PROXY_TOKEN=$(openssl rand -hex 16); ADMIN_TOKEN=$(openssl rand -hex 16)
   echo "Proxy token: $PROXY_TOKEN"; echo "Admin token: $ADMIN_TOKEN"
   echo "$PROXY_TOKEN" | npx wrangler secret put PROXY_TOKEN
   echo "$ADMIN_TOKEN" | npx wrangler secret put ADMIN_TOKEN
   ```

## Use

1. In the Auday app on the iPhone, change the AI service address to this (with your address and proxy token), and enter your Gemini API key as usual:

   ```
   https://auday-capture.<your-subdomain>.workers.dev/<proxy-token>/v1beta/openai
   ```

2. Use Auday as usual. To list the recorded requests, run this with your address and admin token. It returns up to 1000 entries; if `cursor` in the reply is not null, add `?cursor=<cursor>` to the address to get the next page:

   ```bash
   curl -H "Authorization: Bearer <admin-token>" https://auday-capture.<your-subdomain>.workers.dev/admin/list
   ```

3. To read one of them, use an `id` from the list:

   ```bash
   curl -H "Authorization: Bearer <admin-token>" "https://auday-capture.<your-subdomain>.workers.dev/admin/get?id=<id>"
   ```

When you are done, set Auday's AI service address back to what it was. To remove the proxy and its records completely, run `npx wrangler delete`, then delete `LOGS` in the Cloudflare dashboard under Storage & Databases › KV.

## Test

No automated tests. After deploying, step 2 of Use shows whether it works.

## More documentation

- [docs/AUDAY_OBSERVATIONS.md](../../docs/AUDAY_OBSERVATIONS.md): what this tool revealed about how Auday works
