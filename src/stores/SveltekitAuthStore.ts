import { BaseAuthStore } from "./BaseAuthStore";
import type { Cookies } from "@sveltejs/kit";

// Derived from `Cookies` so the option types follow the installed SvelteKit version
// (Kit 2 requires `path`, Kit 3 makes it optional and uses cookie 1.x's `SerializeOptions`).
type CookieSetOptions = NonNullable<Parameters<Cookies["set"]>[2]>;
type CookieDeleteOptions = NonNullable<Parameters<Cookies["delete"]>[1]>;

const defaultCookieKey = "pb_auth";

export class SvelteKitAuthStore extends BaseAuthStore {
    constructor() {
        super();
    }

    getCookie() {
        const cookieString = this.exportToCookie({
            encode: (s) => `${s}`,
        });

        return cookieString.split("=")[1].split(";")[0];
    }

    saveCookie(
        cookies: Cookies,
        key = defaultCookieKey,
        opts: CookieSetOptions = {
            path: "/",
        },
    ) {
        const cookieString = this.exportToCookie({
            encode: (s) => `${s}`,
        });
        cookies.set(key, cookieString.split("=")[1].split(";")[0], opts);
    }

    clearCookie(
        cookies: Cookies,
        key = defaultCookieKey,
        opts: CookieDeleteOptions = {
            path: "/",
        },
    ) {
        cookies.delete(key, opts);
    }
}
