#!/usr/bin/env node
/**
 * Get Safari cookies for a specific domain using @mherod/get-cookie
 * Usage: node get-safari-cookies.js <domain>
 * Output: JSON array of cookies
 */

const { getCookie } = require('@mherod/get-cookie');

const domain = process.argv[2] || 'claude.ai';

async function getSafariCookies() {
    try {
        // Get all cookies for the domain from Safari
        const cookies = await getCookie({
            name: '%',  // wildcard - get all cookies
            domain: domain,
            browser: 'safari'
        });

        if (!cookies || cookies.length === 0) {
            console.error(JSON.stringify({error: `No cookies found for ${domain}`}));
            process.exit(1);
        }

        // Convert to the format we need
        const formatted = cookies.map(c => ({
            domain: c.domain || domain,
            name: c.name,
            value: c.value,
            path: c.path || '/',
            expiresDate: c.expirationDate ? new Date(c.expirationDate * 1000).toISOString() : null,
            secure: c.secure || false,
            httpOnly: c.httpOnly || false
        }));

        console.log(JSON.stringify(formatted, null, 2));
        process.exit(0);

    } catch (error) {
        console.error(JSON.stringify({
            error: error.message,
            stack: error.stack
        }));
        process.exit(1);
    }
}

getSafariCookies();
