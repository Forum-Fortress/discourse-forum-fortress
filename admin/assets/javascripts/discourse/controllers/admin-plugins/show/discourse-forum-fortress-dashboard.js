import { tracked } from "@glimmer/tracking";
import Controller from "@ember/controller";
import { action } from "@ember/object";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";

export default class AdminPluginsShowDiscourseForumFortressDashboardController extends Controller {
  @tracked model;
  @tracked testing = false;
  @tracked testResult;

  get connectionState() {
    if (!this.model?.enabled) {
      return "disabled";
    }

    if (this.testResult?.ok) {
      return "connected";
    }

    if (this.testResult && !this.testResult.ok) {
      return "unreachable";
    }

    if (this.model.configured && this.model.site_registered) {
      return "configured";
    }

    return "setup";
  }

  get connectionClass() {
    return `forum-fortress-admin__pill--${this.connectionState}`;
  }

  get connectionLabel() {
    return `forum_fortress.admin.connection_states.${this.connectionState}`;
  }

  get communicationLabel() {
    if (this.testResult?.ok) {
      return "forum_fortress.admin.reachable";
    }

    if (this.testResult && !this.testResult.ok) {
      return "forum_fortress.admin.unreachable";
    }

    return "forum_fortress.admin.not_tested";
  }

  get preferredEndpoint() {
    return this.model?.preferred_endpoint || null;
  }

  @action
  async testConnection() {
    this.testing = true;
    this.testResult = undefined;

    try {
      this.testResult = await ajax("/forum-fortress/test.json", {
        method: "POST",
      });
    } catch (error) {
      this.testResult = { ok: false, error_code: "connection_failed" };
      popupAjaxError(error);
    } finally {
      try {
        this.model = await ajax("/forum-fortress/status.json");
      } catch {
        // Keep the last safe status model if the refresh fails.
      }
      this.testing = false;
    }
  }
}
