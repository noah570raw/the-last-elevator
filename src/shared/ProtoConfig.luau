--!strict
-- Prototype rules: DEC-01 (capture), DEC-02 (attachment), DEC-04 (persistence).

return table.freeze({
	ROOM_ID = "ROOM-01",
	SOCKET_ID = "Socket_A",

	-- DEC-01
	START_HOLD = 0.5,
	CAPTURE_SECONDS = 8,
	CAPTURE_TICK = 0.25,
	ZONE_GRACE = 1,

	-- DEC-02
	CONFIRM_HOLD = 1.5,
	PREVIEW_MAX_DISTANCE = 12,
	PREVIEW_TIMEOUT = 20,
	SAVE_ATTEMPTS = 3,
	SAVE_BACKOFF = table.freeze({ 1, 2 }),

	-- DEC-04
	SCHEMA = 1,
	STORE_NAME = "TLE_Proto_v1",
	LOAD_ATTEMPTS = 3,
	BACKEND_ATTRIBUTE = "TLE_StoreBackend", -- Workspace attribute: "memory" (default) | "datastore"
	MSG_PROFILE_UNAVAILABLE = "Профиль недоступен. Попробуй войти снова.",
	MSG_PROFILE_LOADING = "Профиль загружается…",

	-- Instance names
	REMOTES = "TLE_Remotes",
	TEMPLATES = "TLE_Templates",
	MODULE_TEMPLATE = "ROOM01_Module",
	ATTACHED_FOLDER = "TLE_Attached",
	GREYBOX = "TLE_Greybox",
})
