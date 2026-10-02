# pocketbase-sveltekit changelog

Changes specific to this fork. Everything else comes from upstream
[pocketbase/js-sdk](https://github.com/pocketbase/js-sdk) and is listed in
`CHANGELOG.md`.

Each release uses upstream's version number when it is free on npm. If a
fork-only release has already taken that number, the release goes out as the
next free patch version.

## 0.28.2

- `SvelteKitAuthStore` cookie option types now derive from SvelteKit's own `Cookies` type instead of `cookie`'s `CookieSerializeOptions`, so they match both SvelteKit 2 and 3 (where `path` is optional).

- Declared `@sveltejs/kit` (`^2.0.0 || ^3.0.0`) as an optional peer dependency.
