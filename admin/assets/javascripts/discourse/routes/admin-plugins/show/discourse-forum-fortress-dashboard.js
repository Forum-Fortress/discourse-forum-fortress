import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DiscourseRoute from "discourse/routes/discourse";
import { i18n } from "discourse-i18n";

export default class AdminPluginsShowDiscourseForumFortressDashboardRoute extends DiscourseRoute {
  async model() {
    try {
      return await ajax("/forum-fortress/status.json");
    } catch (error) {
      popupAjaxError(error);
      return {
        enabled: false,
        configured: false,
        site_registered: false,
        protections: {},
      };
    }
  }

  titleToken() {
    return i18n("forum_fortress.admin.dashboard");
  }
}
