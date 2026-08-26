export default {
  resource: "admin.adminPlugins.show",
  path: "/plugins",

  map() {
    this.route("discourse-forum-fortress-dashboard", { path: "dashboard" });
  },
};
