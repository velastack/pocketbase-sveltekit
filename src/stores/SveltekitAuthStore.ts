import { BaseAuthStore } from "./BaseAuthStore";
import type { Cookies } from "@sveltejs/kit";
import type { CookieSerializeOptions } from "cookie";

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
        opts: CookieSerializeOptions & {
            path: string;
        } = {
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
        opts: CookieSerializeOptions & { path: string } = {
            path: "/",
        },
    ) {
        cookies.delete(key, opts);
    }
}
