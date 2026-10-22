//! MIXEL website and project links (Help menu, About, start screen, CLI, MCP).

use serde_json::{Value, json};

/// The app's legacy internal slug.
pub const APP: &str = "designcraft";
/// The MIXEL company website.
pub const WEBSITE: &str = "https://www.mixel.ch";
/// MIXEL Design's project page.
pub const APP_PAGE: &str = "https://github.com/jangopeopleV2/mixel-design";
/// MIXEL Design's source repository.
pub const GITHUB: &str = "https://github.com/jangopeopleV2/mixel-design";
/// Where to report bugs and request features.
pub const ISSUES: &str = "https://github.com/jangopeopleV2/mixel-design/issues";

/// All links as JSON (the `app.links` command).
pub fn all() -> Value {
    json!({
        "website": WEBSITE,
        "appPage": APP_PAGE,
        "github": GITHUB,
        "issues": ISSUES,
    })
}

/// A link by key (`website`, `appPage`, `github`, `issues`).
pub fn get(key: &str) -> Option<&'static str> {
    Some(match key {
        "website" => WEBSITE,
        "appPage" => APP_PAGE,
        "github" => GITHUB,
        "issues" => ISSUES,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn links_follow_the_app_slug() {
        assert!(APP_PAGE.starts_with("https://github.com/jangopeopleV2/mixel-design"));
        assert!(GITHUB.starts_with("https://github.com/jangopeopleV2/mixel-design"));
        assert!(ISSUES.starts_with(GITHUB));
        assert_eq!(WEBSITE, "https://www.mixel.ch");
        assert!(get("discord").is_none());
        assert!(all().get("discord").is_none());
        for k in ["website", "appPage", "github", "issues"] {
            assert!(get(k).is_some_and(|u| u.starts_with("https://")), "{k}");
            assert_eq!(all()[k], get(k).unwrap());
        }
    }
}
