import { not } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";

export default <template>
  <section class="forum-fortress-admin admin-detail">
    <div class="forum-fortress-admin__card forum-fortress-admin__hero">
      <div class="forum-fortress-admin__hero-header">
        <div class="forum-fortress-admin__mark" aria-hidden="true">
          <i></i>
          <i></i>
          <i></i>
        </div>

        <div class="forum-fortress-admin__hero-copy">
          <h2>{{i18n "forum_fortress.admin.overview"}}</h2>
          <p>{{i18n "forum_fortress.admin.tagline"}}</p>
        </div>

        <span
          class="forum-fortress-admin__pill {{@controller.connectionClass}}"
        >
          {{i18n @controller.connectionLabel}}
        </span>
      </div>

      <div class="forum-fortress-admin__actions">
        <DButton
          @href="/forum-fortress/portal.json"
          @disabled={{not @controller.model.configured}}
          @icon="arrow-up-right-from-square"
          @label="forum_fortress.admin.portal_login"
          class="btn-primary forum-fortress-admin__action forum-fortress-admin__action--portal"
          target="_blank"
          rel="noopener"
        />
        <DButton
          @action={{@controller.testConnection}}
          @disabled={{not @controller.model.enabled}}
          @icon="plug"
          @isLoading={{@controller.testing}}
          @label="forum_fortress.admin.test_connection"
          class="btn-default forum-fortress-admin__action"
        />
        <DButton
          @href="/admin/plugins/discourse-forum-fortress/settings"
          @icon="gear"
          @label="forum_fortress.admin.settings_link_short"
          class="btn-default forum-fortress-admin__action"
        />
      </div>
    </div>

    {{#if @controller.testResult}}
      {{#if @controller.testResult.ok}}
        <div
          class="forum-fortress-admin__notice forum-fortress-admin__notice--success"
          role="status"
        >
          {{dIcon "circle-check"}}
          <span>{{i18n "forum_fortress.admin.test_success"}}</span>
        </div>
      {{else}}
        <div
          class="forum-fortress-admin__notice forum-fortress-admin__notice--error"
          role="alert"
        >
          {{dIcon "circle-exclamation"}}
          <span>{{i18n "forum_fortress.admin.test_failure"}}</span>
        </div>
      {{/if}}
    {{/if}}

    <div class="forum-fortress-admin__card forum-fortress-admin__status-card">
      <div class="forum-fortress-admin__section-header">
        <div>
          <h3>{{i18n "forum_fortress.admin.site_status"}}</h3>
          <p>{{i18n "forum_fortress.admin.status_summary"}}</p>
        </div>
      </div>

      <div class="forum-fortress-admin__metrics">
        <div class="forum-fortress-admin__metric">
          <span>{{i18n "forum_fortress.admin.protection"}}</span>
          {{#if @controller.model.enabled}}
            <strong class="forum-fortress-admin__value--good">{{i18n
                "forum_fortress.admin.enabled"
              }}</strong>
          {{else}}
            <strong>{{i18n "forum_fortress.admin.disabled"}}</strong>
          {{/if}}
        </div>

        <div class="forum-fortress-admin__metric">
          <span>{{i18n "forum_fortress.admin.configuration"}}</span>
          {{#if @controller.model.configured}}
            <strong class="forum-fortress-admin__value--good">{{i18n
                "forum_fortress.admin.ready"
              }}</strong>
          {{else}}
            <strong>{{i18n "forum_fortress.admin.not_ready"}}</strong>
          {{/if}}
        </div>

        <div class="forum-fortress-admin__metric">
          <span>{{i18n "forum_fortress.admin.communication"}}</span>
          <strong>{{i18n @controller.communicationLabel}}</strong>
        </div>

        <div class="forum-fortress-admin__metric">
          <span>{{i18n "forum_fortress.admin.region"}}</span>
          <strong>{{@controller.model.region}}</strong>
        </div>

        <div class="forum-fortress-admin__metric">
          <span>{{i18n "forum_fortress.admin.endpoint"}}</span>
          {{#if @controller.preferredEndpoint}}
            <strong title={{@controller.preferredEndpoint}}>
              {{@controller.preferredEndpoint}}
            </strong>
          {{else}}
            <strong>{{i18n "forum_fortress.admin.automatic_selection"}}</strong>
          {{/if}}
        </div>

        <div class="forum-fortress-admin__metric">
          <span>{{i18n "forum_fortress.admin.fail_open"}}</span>
          {{#if @controller.model.fail_open}}
            <strong>{{i18n "forum_fortress.admin.fail_open_enabled"}}</strong>
          {{else}}
            <strong>{{i18n "forum_fortress.admin.fail_open_disabled"}}</strong>
          {{/if}}
        </div>
      </div>
    </div>

    <div class="forum-fortress-admin__lower-grid">
      <div
        class="forum-fortress-admin__card forum-fortress-admin__coverage-card"
      >
        <div class="forum-fortress-admin__section-header">
          <div>
            <h3>{{i18n "forum_fortress.admin.active_protection"}}</h3>
            <p>{{i18n "forum_fortress.admin.protection_summary"}}</p>
          </div>
        </div>

        <ul class="forum-fortress-admin__coverage">
          <li>
            <span class="forum-fortress-admin__coverage-icon">
              {{dIcon "user-plus"}}
            </span>
            <div>
              <strong>{{i18n "forum_fortress.admin.registration"}}</strong>
              <span>{{i18n "forum_fortress.admin.registration_help"}}</span>
            </div>
            <span class="forum-fortress-admin__coverage-state">
              {{#if @controller.model.enabled}}
                {{i18n "forum_fortress.admin.active"}}
              {{else}}
                {{i18n "forum_fortress.admin.paused"}}
              {{/if}}
            </span>
          </li>
          <li>
            <span class="forum-fortress-admin__coverage-icon">
              {{dIcon "comments"}}
            </span>
            <div>
              <strong>{{i18n "forum_fortress.admin.public_posts"}}</strong>
              <span>{{i18n "forum_fortress.admin.public_posts_help"}}</span>
            </div>
            <span class="forum-fortress-admin__coverage-state">
              {{#if @controller.model.enabled}}
                {{i18n "forum_fortress.admin.active"}}
              {{else}}
                {{i18n "forum_fortress.admin.paused"}}
              {{/if}}
            </span>
          </li>
          <li>
            <span class="forum-fortress-admin__coverage-icon">
              {{dIcon "pen"}}
            </span>
            <div>
              <strong>{{i18n "forum_fortress.admin.post_edits"}}</strong>
              <span>{{i18n "forum_fortress.admin.post_edits_help"}}</span>
            </div>
            <span class="forum-fortress-admin__coverage-state">
              {{#if @controller.model.enabled}}
                {{i18n "forum_fortress.admin.active"}}
              {{else}}
                {{i18n "forum_fortress.admin.paused"}}
              {{/if}}
            </span>
          </li>
          <li>
            <span class="forum-fortress-admin__coverage-icon">
              {{dIcon "address-card"}}
            </span>
            <div>
              <strong>{{i18n "forum_fortress.admin.profiles"}}</strong>
              <span>{{i18n "forum_fortress.admin.profiles_help"}}</span>
            </div>
            <span class="forum-fortress-admin__coverage-state">
              {{#if @controller.model.enabled}}
                {{i18n "forum_fortress.admin.active"}}
              {{else}}
                {{i18n "forum_fortress.admin.paused"}}
              {{/if}}
            </span>
          </li>
        </ul>
      </div>

      <div class="forum-fortress-admin__card forum-fortress-admin__next-step">
        <div class="forum-fortress-admin__section-header">
          <div>
            <h3>{{i18n "forum_fortress.admin.next_step"}}</h3>
            <p>{{i18n "forum_fortress.admin.next_step_summary"}}</p>
          </div>
        </div>

        <div class="forum-fortress-admin__next-step-body">
          {{#if @controller.model.enabled}}
            {{#if @controller.model.configured}}
              <div class="forum-fortress-admin__next-step-icon">
                {{dIcon "shield-halved"}}
              </div>
              <h4>{{i18n "forum_fortress.admin.ready_title"}}</h4>
              <p>{{i18n "forum_fortress.admin.ready_help"}}</p>
            {{else if @controller.model.bootstrap_authorized}}
              <div class="forum-fortress-admin__next-step-icon">
                {{dIcon "plug"}}
              </div>
              <h4>{{i18n "forum_fortress.admin.finish_setup"}}</h4>
              <p>{{i18n "forum_fortress.admin.bootstrap_authorized_help"}}</p>
            {{else}}
              <div class="forum-fortress-admin__next-step-icon">
                {{dIcon "gear"}}
              </div>
              <h4>{{i18n "forum_fortress.admin.finish_setup"}}</h4>
              <p>{{i18n "forum_fortress.admin.bootstrap_help"}}</p>
            {{/if}}
          {{else}}
            <div class="forum-fortress-admin__next-step-icon">
              {{dIcon "pause"}}
            </div>
            <h4>{{i18n "forum_fortress.admin.enable_protection"}}</h4>
            <p>{{i18n "forum_fortress.admin.disabled_help"}}</p>
          {{/if}}

          <DButton
            @href="/admin/plugins/discourse-forum-fortress/settings"
            @icon="gear"
            @label="forum_fortress.admin.settings_link"
            class="btn-default"
          />
        </div>
      </div>
    </div>
  </section>
</template>
