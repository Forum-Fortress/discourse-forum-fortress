import { withPluginApi } from "discourse/lib/plugin-api";

const PLUGIN_ID = "discourse-forum-fortress";

export default {
  name: "forum-fortress-admin-plugin-configuration-nav",

  initialize(container) {
    const currentUser = container.lookup("service:current-user");
    if (!currentUser?.admin) {
      return;
    }

    withPluginApi((api) => {
      api.setAdminPluginIcon(PLUGIN_ID, "shield-halved");
      api.addAdminPluginConfigurationNav(PLUGIN_ID, [
        {
          label: "forum_fortress.admin.dashboard",
          route: "adminPlugins.show.discourse-forum-fortress-dashboard",
          description: "forum_fortress.admin.description",
        },
        {
          label: "admin.plugins.change_settings_short",
          route: "adminPlugins.show.settings",
        },
      ]);
    });
  },
};
