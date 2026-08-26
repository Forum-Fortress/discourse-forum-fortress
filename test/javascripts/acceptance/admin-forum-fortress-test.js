import { click, currentURL, visit } from "@ember/test-helpers";
import { test } from "qunit";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";
import { i18n } from "discourse-i18n";

acceptance("Forum Fortress admin dashboard", function (needs) {
  needs.user();

  needs.pretender((server, helper) => {
    server.get("/admin/plugins/discourse-forum-fortress.json", () => {
      return helper.response({
        id: "discourse-forum-fortress",
        name: "discourse-forum-fortress",
        enabled: true,
        has_settings: true,
        humanized_name: "Forum Fortress",
        about: "Forum Fortress anti-spam protection for Discourse",
        admin_route: {
          label: "forum_fortress.admin.title",
          location: "discourse-forum-fortress",
          use_new_show_route: true,
        },
      });
    });

    server.get("/forum-fortress/status.json", () => {
      return helper.response({
        enabled: true,
        configured: true,
        bootstrap_authorized: false,
        site_registered: true,
        region: "global",
        fail_open: true,
        preferred_endpoint: "https://api.ffapi.net",
        protections: {
          registration: true,
          public_posts: true,
          post_edits: true,
          profiles: true,
        },
      });
    });

    server.post("/forum-fortress/test.json", () => {
      return helper.response({
        ok: true,
        health: true,
        site_status: true,
      });
    });
  });

  test("uses the native plugin shell and renders one dashboard", async function (assert) {
    await visit("/admin/plugins/discourse-forum-fortress");

    assert.strictEqual(
      currentURL(),
      "/admin/plugins/discourse-forum-fortress/dashboard",
      "the plugin root redirects to its dashboard route"
    );
    assert
      .dom(".forum-fortress-admin")
      .exists({ count: 1 }, "one Forum Fortress dashboard is rendered");
    assert
      .dom(".admin-plugin-config-page__top-nav-item")
      .exists({ count: 2 }, "dashboard and settings navigation are rendered");
    assert
      .dom(".admin-plugin-config-page__top-nav-item:first-child")
      .hasText(i18n("forum_fortress.admin.dashboard"));
    assert
      .dom(".forum-fortress-admin .d-page-subheader")
      .doesNotExist("the dashboard does not repeat the native plugin header");
    assert
      .dom(".forum-fortress-admin__hero h2")
      .hasText(i18n("forum_fortress.admin.overview"));
    assert.dom(".forum-fortress-admin__coverage > li").exists({ count: 4 });
  });

  test("shows a successful connection result", async function (assert) {
    await visit("/admin/plugins/discourse-forum-fortress/dashboard");
    await click(".forum-fortress-admin__action:not([href])");

    assert
      .dom(".forum-fortress-admin__notice--success")
      .hasText(i18n("forum_fortress.admin.test_success"));
    assert
      .dom(".forum-fortress-admin__pill--connected")
      .hasText(i18n("forum_fortress.admin.connection_states.connected"));
  });
});
