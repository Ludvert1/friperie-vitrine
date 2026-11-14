# Friperie Vitrine — marketplace for local shops (FR/EN)

A single `index.html` file: public directory, shop pages, merchant sign-up and subscriptions, merchant dashboard, and platform admin.
With no configuration it runs in **demo mode** (data stays in the browser):
- Merchant: `vetu@demo.bj` / `demo`  ·  Admin: `admin@vitrine.demo` / `demo`

## Go live (about 30 minutes)
1. **Supabase**: create a project (region: Frankfurt). Open `supabase-setup.sql`, put your admin email in the `admins` line, then paste the whole file into SQL Editor and click Run.
2. **Authentication → Providers → Email**: keep sign-ups **on** (merchants register themselves). If "Confirm email" is on, merchants confirm by email and then sign in. The site finishes creating their shop after that.
3. **Create the admin account**: Authentication → Users → Add user with the same email you put in `admins`.
4. **Project Settings → API**: copy the URL and the `anon` key into `CONFIG` at the top of the script. You can also change `PLATFORM_NAME` there.
5. **Deploy to Vercel** (drag and drop the folder). Add a custom domain such as `vitrine.bj` or `friperies.online`.
6. In **Admin → Settings**, set the platform's MoMo number, support WhatsApp, prices, trial length and limits.

## How it makes money
| | Basic | Premium |
|---|---|---|
| Default price | 2,000 FCFA/month | 5,000 FCFA/month |
| Shop page, WhatsApp/call/website buttons, reviews, stats | ✓ | ✓ |
| Products / gallery photos | 15 / 6 | 200 / 30 |
| "Featured" banner when the app opens | – | ✓ |
| Shown first in search and categories, "Featured products" | – | ✓ |
| Promo message + Premium badge | – | ✓ |

Discounts: 3 months −5%, 6 months −10%, 12 months = 2 months free. The server calculates the price, so the browser can't change it.

## Monthly payment flow
The merchant pays by MoMo and enters the transaction ID → you check it in your MoMo app → **Admin → Payments → Approve** → the subscription is extended and the shop is published.
Shops are hidden automatically after the expiry date plus the grace days. The **Expiring soon** list has a WhatsApp reminder button.

## Security
- Merchants can't change their own plan, status, expiry date, Verified badge, stats or rating. A database trigger enforces this.
- Product and photo limits are enforced on the server.
- Leads, reviews and click tracking go through functions that only accept published shops.
- Each merchant can only upload photos into their own storage folder.
