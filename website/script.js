const root = document.documentElement;
root.classList.add("js");
const themeButton = document.querySelector(".theme-toggle");
const systemTheme = window.matchMedia("(prefers-color-scheme: dark)");

function resolvedTheme() {
    if (root.dataset.theme === "dark" || root.dataset.theme === "light") {
        return root.dataset.theme;
    }
    return systemTheme.matches ? "dark" : "light";
}

function updateThemeButton() {
    const current = resolvedTheme();
    const next = current === "dark" ? "light" : "dark";
    themeButton.setAttribute("aria-label", `Switch to ${next} mode`);
    themeButton.setAttribute("title", `Switch to ${next} mode`);
}

themeButton.addEventListener("click", () => {
    const next = resolvedTheme() === "dark" ? "light" : "dark";
    root.dataset.theme = next;
    localStorage.setItem("kaset-theme", next);
    updateThemeButton();
});

systemTheme.addEventListener("change", updateThemeButton);
updateThemeButton();

const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const revealElements = document.querySelectorAll(".reveal");

if (reducedMotion || !("IntersectionObserver" in window)) {
    revealElements.forEach((element) => element.classList.add("is-visible"));
} else {
    const observer = new IntersectionObserver((entries) => {
        entries.forEach((entry) => {
            if (entry.isIntersecting) {
                entry.target.classList.add("is-visible");
                observer.unobserve(entry.target);
            }
        });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });

    revealElements.forEach((element) => observer.observe(element));
}

function formatBytes(bytes) {
    const megabytes = bytes / 1_000_000;
    return `${megabytes.toFixed(1)} MB ZIP`;
}

async function updateLatestRelease() {
    try {
        const response = await fetch("https://api.github.com/repos/Yoddikko/kasetPlus/releases/latest", {
            headers: { Accept: "application/vnd.github+json" }
        });

        if (!response.ok) {
            return;
        }

        const release = await response.json();
        const zip = release.assets?.find((asset) => asset.name === "KasetPlus.zip");

        if (!release.tag_name || !zip?.browser_download_url) {
            return;
        }

        document.querySelectorAll(".release-version").forEach((element) => {
            element.textContent = release.tag_name;
        });
        document.querySelectorAll(".download-link").forEach((link) => {
            link.href = zip.browser_download_url;
        });

        const size = document.querySelector(".release-size");
        if (size && zip.size) {
            size.textContent = formatBytes(zip.size);
        }
    } catch {
        // Keep the verified release fallback embedded in the page.
    }
}

updateLatestRelease();
