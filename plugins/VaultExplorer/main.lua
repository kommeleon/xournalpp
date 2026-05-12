local CONFIG_FILE_NAME = "vault-explorer.conf"
local DEFAULT_MAX_DEPTH = 4
local MAX_DEPTH_LIMIT = 16

local state = {
  config = {
    root = "",
    maxDepth = DEFAULT_MAX_DEPTH,
  },
  rootLabel = "Notebook",
  tree = { name = "Notebook", path = "", directories = {}, files = {} },
  fileEntries = {},
  menuFiles = {},
  lastScanError = nil,
}

local gui = {
  attempted = false,
  available = false,
  lgi = nil,
  Gtk = nil,
  Gio = nil,
  GObject = nil,
  Pango = nil,
}

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function path_separator()
  return package.config:sub(1, 1)
end

local function normalize_path(path)
  if not path or path == "" then
    return ""
  end

  local sep = path_separator()
  local pattern = sep == "\\" and "[\\/]+" or sep .. "+"
  path = path:gsub(pattern, sep)

  if #path > 1 and path:sub(-1) == sep then
    if not (sep == "\\" and path:match("^%a:[\\/]$")) and path ~= sep then
      path = path:sub(1, -2)
    end
  end

  return path
end

local function join_path(base, child)
  if not base or base == "" then
    return child
  end

  local sep = path_separator()
  if base:sub(-1) == sep then
    return base .. child
  end

  return base .. sep .. child
end

local function basename(path)
  path = normalize_path(path)
  local sep = path_separator()
  return path:match("[^" .. sep .. "]+$") or path
end

local function parent_dir(path)
  path = normalize_path(path)
  local sep = path_separator()
  local pattern = "^(.*)" .. (sep == "\\" and "[\\/]" or sep) .. "[^" .. (sep == "\\" and "\\/" or sep) .. "]+$"
  local parent = path:match(pattern)
  if not parent or parent == "" then
    return ""
  end
  return normalize_path(parent)
end

local function extension(name)
  return (name:match("%.([^.]+)$") or ""):lower()
end

local function is_supported_file(name)
  local ext = extension(name)
  return ext == "xopp" or ext == "pdf"
end

local function compare_by_name(a, b)
  local al = a.name:lower()
  local bl = b.name:lower()
  if al == bl then
    return a.name < b.name
  end
  return al < bl
end

local function clone_array(values)
  local result = {}
  for i, value in ipairs(values) do
    result[i] = value
  end
  return result
end

local function split_terms(query)
  local terms = {}
  for part in query:lower():gmatch("%S+") do
    table.insert(terms, part)
  end
  return terms
end

local function ensure_gui()
  if gui.attempted then
    return gui.available
  end

  gui.attempted = true

  local ok, lgi = pcall(require, "lgi")
  if not ok then
    return false
  end

  local okGtk, Gtk = pcall(lgi.require, "Gtk", "3.0")
  if not okGtk then
    return false
  end

  gui.available = true
  gui.lgi = lgi
  gui.Gtk = Gtk
  gui.Gio = lgi.Gio
  gui.GObject = lgi.GObject
  gui.Pango = lgi.Pango
  return true
end

local function config_file_path()
  return join_path(app.getFolder("config"), CONFIG_FILE_NAME)
end

local function save_config()
  local fh, err = io.open(config_file_path(), "w")
  if not fh then
    return nil, err
  end

  fh:write("root=", state.config.root or "", "\n")
  fh:write("maxDepth=", tostring(state.config.maxDepth or DEFAULT_MAX_DEPTH), "\n")
  fh:close()
  return true
end

local function load_config()
  state.config.root = ""
  state.config.maxDepth = DEFAULT_MAX_DEPTH

  local fh = io.open(config_file_path(), "r")
  if not fh then
    return
  end

  for line in fh:lines() do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key and value then
      key = trim(key)
      if key == "root" then
        state.config.root = normalize_path(trim(value))
      elseif key == "maxDepth" then
        local maxDepth = tonumber(trim(value))
        if maxDepth then
          state.config.maxDepth = math.max(0, math.min(MAX_DEPTH_LIMIT, math.floor(maxDepth)))
        end
      end
    end
  end

  fh:close()
end

local function show_message(message, is_error)
  app.openDialog(message, { "OK" }, "", is_error == true)
end

local function require_gui(feature)
  if ensure_gui() then
    return true
  end

  show_message(
    feature .. " requires the Lua lgi/LuaGObject package.\n\n" ..
    "On Linux, install lua-lgi. On Windows and macOS, use a release that ships LuaGObject.",
    true)
  return false
end

local function directory_exists(path)
  if not ensure_gui() or not path or path == "" then
    return false
  end

  local ok, fileType = pcall(function()
    local file = gui.Gio.File.new_for_path(path)
    return file:query_file_type(gui.Gio.FileQueryInfoFlags.NONE, nil)
  end)

  return ok and fileType == gui.Gio.FileType.DIRECTORY
end

local function enumerate_directory(path)
  local file = gui.Gio.File.new_for_path(path)
  local enumerator = file:enumerate_children(
    "standard::name,standard::type,standard::is-hidden",
    gui.Gio.FileQueryInfoFlags.NONE,
    nil)

  local entries = {}
  while true do
    local info = enumerator:next_file(nil)
    if not info then
      break
    end

    local name = info:get_name()
    if name and name ~= "" and not info:get_is_hidden() and not name:match("^%.") then
      table.insert(entries, {
        name = name,
        path = join_path(path, name),
        fileType = info:get_file_type(),
      })
    end
  end

  enumerator:close(nil)
  table.sort(entries, compare_by_name)
  return entries
end

local function scan_directory(path, depth, breadcrumb)
  local node = {
    name = basename(path),
    path = path,
    directories = {},
    files = {},
  }
  local flatFiles = {}

  local entries = enumerate_directory(path)
  for _, entry in ipairs(entries) do
    if entry.fileType == gui.Gio.FileType.DIRECTORY then
      if depth < state.config.maxDepth then
        local nextBreadcrumb = clone_array(breadcrumb)
        table.insert(nextBreadcrumb, entry.name)
        local childNode, childFiles = scan_directory(entry.path, depth + 1, nextBreadcrumb)
        if #childNode.directories > 0 or #childNode.files > 0 then
          table.insert(node.directories, childNode)
          for _, fileEntry in ipairs(childFiles) do
            table.insert(flatFiles, fileEntry)
          end
        end
      end
    elseif entry.fileType == gui.Gio.FileType.REGULAR and is_supported_file(entry.name) then
      local fileEntry = {
        name = entry.name,
        path = entry.path,
        breadcrumb = clone_array(breadcrumb),
      }
      fileEntry.breadcrumbText = #fileEntry.breadcrumb > 0 and table.concat(fileEntry.breadcrumb, " > ") or state.rootLabel
      table.insert(node.files, fileEntry)
      table.insert(flatFiles, fileEntry)
    end
  end

  return node, flatFiles
end

local function rebuild_index()
  state.rootLabel = "Notebook"
  state.tree = { name = "Notebook", path = "", directories = {}, files = {} }
  state.fileEntries = {}
  state.lastScanError = nil

  if state.config.root == "" then
    state.lastScanError = "Notebook root is not configured."
    return false, state.lastScanError
  end

  if not ensure_gui() then
    state.lastScanError = "Lua lgi/LuaGObject is required to scan folders."
    return false, state.lastScanError
  end

  local root = normalize_path(state.config.root)
  if not directory_exists(root) then
    state.lastScanError = "Notebook root does not exist:\n" .. root
    return false, state.lastScanError
  end

  state.rootLabel = basename(root)

  local ok, node, filesOrErr = pcall(function()
    local tree, files = scan_directory(root, 0, {})
    return tree, files
  end)

  if not ok then
    state.lastScanError = tostring(node)
    return false, state.lastScanError
  end

  state.tree = node
  state.fileEntries = filesOrErr
  return true
end

local function current_document_folder()
  local doc = app.getDocumentStructure()
  local path = doc.xoppFilename
  if not path or path == "" then
    path = doc.pdfBackgroundFilename
  end
  if not path or path == "" then
    return nil
  end

  local folder = parent_dir(path)
  if folder == "" then
    return nil
  end
  return folder
end

local function set_root(root)
  root = normalize_path(root or "")
  if root == "" then
    return nil, "Notebook root cannot be empty."
  end

  if not directory_exists(root) then
    return nil, "Notebook root does not exist:\n" .. root
  end

  state.config.root = root
  local ok, err = save_config()
  if not ok then
    return nil, "Failed to save settings:\n" .. tostring(err)
  end

  return rebuild_index()
end

local function refresh_notice()
  show_message(
    "Notebook index refreshed.\n\n" ..
    "Quick Open and Browse Notebook now use the latest scan.\n" ..
    "The static Plugin menu tree is created only during plugin initialization, so it updates after restarting Xournal++.",
    false)
end

local function open_path(path)
  if not path or path == "" then
    show_message("Nothing to open.", true)
    return
  end

  app.openFile(path)
end

local function first_visible_row(listbox)
  for _, child in ipairs(listbox:get_children()) do
    if child:get_visible() then
      return child
    end
  end
  return nil
end

local function clear_container(widget)
  for _, child in ipairs(widget:get_children()) do
    widget:remove(child)
  end
end

local function build_result_row(entry)
  local Gtk = gui.Gtk
  local Pango = gui.Pango

  local title = Gtk.Label({
    label = "📄 " .. entry.name,
    xalign = 0,
    hexpand = true,
  })
  title:set_ellipsize(Pango.EllipsizeMode.END)

  local breadcrumb = Gtk.Label({
    label = entry.breadcrumbText,
    xalign = 0,
    hexpand = true,
  })
  breadcrumb:set_ellipsize(Pango.EllipsizeMode.END)
  breadcrumb:get_style_context():add_class("dim-label")

  local box = Gtk.Box({
    orientation = Gtk.Orientation.VERTICAL,
    spacing = 2,
    margin_top = 6,
    margin_bottom = 6,
    margin_start = 8,
    margin_end = 8,
  })
  box:pack_start(title, false, false, 0)
  box:pack_start(breadcrumb, false, false, 0)

  local row = Gtk.ListBoxRow()
  row:add(box)
  row._entry = entry
  return row
end

local function create_search_results(query)
  local normalized = trim(query or "")
  if normalized == "" then
    return state.fileEntries
  end

  local terms = split_terms(normalized)
  local matches = {}
  for _, entry in ipairs(state.fileEntries) do
    local haystack = (entry.name .. " " .. entry.breadcrumbText):lower()
    local include = true
    for _, term in ipairs(terms) do
      if not haystack:find(term, 1, true) then
        include = false
        break
      end
    end
    if include then
      table.insert(matches, entry)
    end
  end

  return matches
end

local function show_quick_open_dialog()
  if not require_gui("Quick Open") then
    return
  end

  local ok, err = rebuild_index()
  if not ok then
    show_message(err, true)
    return
  end

  local Gtk = gui.Gtk

  local dialog = Gtk.Dialog({
    title = "Quick Open – " .. state.rootLabel,
    modal = true,
    default_width = 760,
    default_height = 520,
    use_header_bar = true,
  })
  dialog:add_button("Close", Gtk.ResponseType.CLOSE)

  local content = dialog:get_content_area()
  content.spacing = 8
  content.margin_top = 8
  content.margin_bottom = 8
  content.margin_start = 8
  content.margin_end = 8

  local hint = Gtk.Label({
    label = "Search .xopp and .pdf files. Press Enter to open the selected result.",
    xalign = 0,
  })

  local search = Gtk.SearchEntry({
    hexpand = true,
    placeholder_text = "Search by file name or breadcrumb",
  })

  local status = Gtk.Label({ xalign = 0 })

  local listbox = Gtk.ListBox({
    activate_on_single_click = true,
    selection_mode = Gtk.SelectionMode.BROWSE,
  })

  local scroll = Gtk.ScrolledWindow({
    hexpand = true,
    vexpand = true,
    shadow_type = Gtk.ShadowType.IN,
  })
  scroll:add(listbox)

  content:pack_start(hint, false, false, 0)
  content:pack_start(search, false, false, 0)
  content:pack_start(status, false, false, 0)
  content:pack_start(scroll, true, true, 0)

  local function populate()
    clear_container(listbox)

    local results = create_search_results(search.text)
    local limit = math.min(#results, 200)
    if limit == 0 then
      local empty = Gtk.Label({
        label = "No matching notes.",
        xalign = 0,
        margin_top = 12,
        margin_start = 8,
      })
      listbox:add(Gtk.ListBoxRow({ child = empty }))
      status.label = "0 results"
    else
      for i = 1, limit do
        listbox:add(build_result_row(results[i]))
      end
      status.label = string.format("%d result%s", #results, #results == 1 and "" or "s")
      if #results > limit then
        status.label = status.label .. string.format(" (showing first %d)", limit)
      end
    end

    listbox:show_all()
    local row = first_visible_row(listbox)
    if row then
      listbox:select_row(row)
    end
  end

  listbox.on_row_activated = function(_, row)
    if row and row._entry then
      open_path(row._entry.path)
      dialog:response(Gtk.ResponseType.CLOSE)
    end
  end

  search.on_changed = populate
  search.on_activate = function()
    local row = listbox:get_selected_row() or first_visible_row(listbox)
    if row and row._entry then
      open_path(row._entry.path)
      dialog:response(Gtk.ResponseType.CLOSE)
    end
  end

  populate()
  dialog:show_all()
  dialog:run()
  dialog:destroy()
end

local function find_node_by_path(node, path)
  if node.path == path then
    return node
  end

  for _, child in ipairs(node.directories) do
    local match = find_node_by_path(child, path)
    if match then
      return match
    end
  end

  return nil
end

local function build_browser_row(item)
  local Gtk = gui.Gtk
  local label = item.kind == "directory" and ("📁 " .. item.node.name) or ("📄 " .. item.file.name)
  local row = Gtk.ListBoxRow()
  row:add(Gtk.Label({
    label = label,
    xalign = 0,
    margin_top = 8,
    margin_bottom = 8,
    margin_start = 8,
    margin_end = 8,
  }))
  row._vault_item = item
  return row
end

local function show_browser_dialog()
  if not require_gui("Browse Notebook") then
    return
  end

  local ok, err = rebuild_index()
  if not ok then
    show_message(err, true)
    return
  end

  local Gtk = gui.Gtk
  local dialog = Gtk.Dialog({
    title = "Browse Notebook – " .. state.rootLabel,
    modal = true,
    default_width = 640,
    default_height = 520,
    use_header_bar = true,
  })
  dialog:add_button("Close", Gtk.ResponseType.CLOSE)

  local content = dialog:get_content_area()
  content.spacing = 8
  content.margin_top = 8
  content.margin_bottom = 8
  content.margin_start = 8
  content.margin_end = 8

  local breadcrumb = Gtk.Label({ xalign = 0 })

  local buttonBox = Gtk.Box({
    orientation = Gtk.Orientation.HORIZONTAL,
    spacing = 6,
  })
  local upButton = Gtk.Button({ label = "Up" })
  local refreshButton = Gtk.Button({ label = "Refresh" })
  buttonBox:pack_start(upButton, false, false, 0)
  buttonBox:pack_start(refreshButton, false, false, 0)

  local listbox = Gtk.ListBox({
    activate_on_single_click = true,
    selection_mode = Gtk.SelectionMode.BROWSE,
  })
  local scroll = Gtk.ScrolledWindow({
    hexpand = true,
    vexpand = true,
    shadow_type = Gtk.ShadowType.IN,
  })
  scroll:add(listbox)

  content:pack_start(breadcrumb, false, false, 0)
  content:pack_start(buttonBox, false, false, 0)
  content:pack_start(scroll, true, true, 0)

  local currentPath = state.tree.path

  local function render()
    clear_container(listbox)

    local node = find_node_by_path(state.tree, currentPath) or state.tree
    currentPath = node.path

    local parts = { state.rootLabel }
    local parent = parent_dir(node.path)
    while parent ~= "" and parent ~= state.config.root do
      table.insert(parts, 2, basename(parent))
      parent = parent_dir(parent)
    end
    if node.path ~= state.config.root then
      table.insert(parts, basename(node.path))
    end
    breadcrumb.label = table.concat(parts, " > ")

    upButton.sensitive = node.path ~= state.config.root

    for _, child in ipairs(node.directories) do
      listbox:add(build_browser_row({ kind = "directory", node = child }))
    end
    for _, fileEntry in ipairs(node.files) do
      listbox:add(build_browser_row({ kind = "file", file = fileEntry }))
    end

    if #node.directories == 0 and #node.files == 0 then
      listbox:add(Gtk.ListBoxRow({
        child = Gtk.Label({
          label = "This folder contains no visible .xopp or .pdf files.",
          xalign = 0,
          margin_top = 12,
          margin_start = 8,
        }),
      }))
    end

    listbox:show_all()
    local row = first_visible_row(listbox)
    if row then
      listbox:select_row(row)
    end
  end

  upButton.on_clicked = function()
    if currentPath ~= state.config.root then
      currentPath = parent_dir(currentPath)
      render()
    end
  end

  refreshButton.on_clicked = function()
    local okRefresh, errRefresh = rebuild_index()
    if not okRefresh then
      show_message(errRefresh, true)
      return
    end
    render()
  end

  listbox.on_row_activated = function(_, row)
    local item = row and row._vault_item
    if not item then
      return
    end

    if item.kind == "directory" then
      currentPath = item.node.path
      render()
    else
      open_path(item.file.path)
      dialog:response(Gtk.ResponseType.CLOSE)
    end
  end

  render()
  dialog:show_all()
  dialog:run()
  dialog:destroy()
end

local function show_settings_dialog()
  if not require_gui("Settings") then
    return
  end

  local Gtk = gui.Gtk

  local dialog = Gtk.Dialog({
    title = "Vault Explorer Settings",
    modal = true,
    default_width = 560,
    use_header_bar = true,
  })
  dialog:add_button("Cancel", Gtk.ResponseType.CANCEL)
  dialog:add_button("Save", Gtk.ResponseType.OK)

  local content = dialog:get_content_area()
  content.spacing = 8
  content.margin_top = 8
  content.margin_bottom = 8
  content.margin_start = 8
  content.margin_end = 8

  local rootLabel = Gtk.Label({
    label = "Notebook root",
    xalign = 0,
  })
  local rootEntry = Gtk.Entry({
    text = state.config.root or "",
    hexpand = true,
  })
  local browseButton = Gtk.Button({ label = "Browse…" })
  local currentButton = Gtk.Button({ label = "Use current document folder" })
  local depthLabel = Gtk.Label({
    label = "Maximum depth",
    xalign = 0,
  })
  local depthSpin = Gtk.SpinButton({
    adjustment = Gtk.Adjustment({
      lower = 0,
      upper = MAX_DEPTH_LIMIT,
      step_increment = 1,
      page_increment = 1,
      value = state.config.maxDepth or DEFAULT_MAX_DEPTH,
    }),
    numeric = true,
  })
  local note = Gtk.Label({
    label =
      "Refresh updates Quick Open and Browse Notebook immediately. " ..
      "Static Plugin menu entries refresh after restarting Xournal++.",
    xalign = 0,
    wrap = true,
  })
  note:get_style_context():add_class("dim-label")

  local rootBox = Gtk.Box({
    orientation = Gtk.Orientation.HORIZONTAL,
    spacing = 6,
  })
  rootBox:pack_start(rootEntry, true, true, 0)
  rootBox:pack_start(browseButton, false, false, 0)

  content:pack_start(rootLabel, false, false, 0)
  content:pack_start(rootBox, false, false, 0)
  content:pack_start(currentButton, false, false, 0)
  content:pack_start(depthLabel, false, false, 0)
  content:pack_start(depthSpin, false, false, 0)
  content:pack_start(note, false, false, 0)

  browseButton.on_clicked = function()
    local chooser = Gtk.FileChooserDialog({
      title = "Select notebook root",
      transient_for = dialog,
      modal = true,
      action = Gtk.FileChooserAction.SELECT_FOLDER,
    })
    chooser:add_button("Cancel", Gtk.ResponseType.CANCEL)
    chooser:add_button("Select", Gtk.ResponseType.ACCEPT)

    if rootEntry.text ~= "" then
      chooser:set_filename(rootEntry.text)
    end

    if chooser:run() == Gtk.ResponseType.ACCEPT then
      local filename = chooser:get_filename()
      if filename and filename ~= "" then
        rootEntry.text = filename
      end
    end

    chooser:destroy()
  end

  currentButton.on_clicked = function()
    local folder = current_document_folder()
    if not folder then
      show_message("No open .xopp or PDF document is available.", true)
      return
    end
    rootEntry.text = folder
  end

  dialog:show_all()
  local response = dialog:run()
  local selectedRoot = normalize_path(rootEntry.text or "")
  local selectedDepth = math.max(0, math.min(MAX_DEPTH_LIMIT, depthSpin:get_value_as_int()))
  dialog:destroy()

  if response ~= Gtk.ResponseType.OK then
    return
  end

  if selectedRoot == "" then
    show_message("Notebook root cannot be empty.", true)
    return
  end

  if not directory_exists(selectedRoot) then
    show_message("Notebook root does not exist:\n" .. selectedRoot, true)
    return
  end

  state.config.root = selectedRoot
  state.config.maxDepth = selectedDepth

  local ok, err = save_config()
  if not ok then
    show_message("Failed to save settings:\n" .. tostring(err), true)
    return
  end

  local rebuilt, rebuildErr = rebuild_index()
  if not rebuilt then
    show_message(rebuildErr, true)
    return
  end

  refresh_notice()
end

local function register_file_menu(menuPath, fileEntry)
  table.insert(state.menuFiles, fileEntry)
  app.registerUi({
    menu = menuPath,
    callback = "OpenIndexedFile",
    mode = #state.menuFiles,
  })
end

local function register_tree_menu(node, prefix)
  for _, directory in ipairs(node.directories) do
    register_tree_menu(directory, prefix .. "/📁 " .. directory.name)
  end
  for _, fileEntry in ipairs(node.files) do
    register_file_menu(prefix .. "/📄 " .. fileEntry.name, fileEntry)
  end
end

load_config()
rebuild_index()

function initUi()
  app.registerUi({
    menu = "⚡ Quick Open…",
    callback = "ShowQuickOpen",
    accelerator = "<Control><Shift>o",
  })
  app.registerUi({
    menu = "🗂 Browse Notebook…",
    callback = "ShowBrowser",
  })
  app.registerUi({
    menu = "🔄 Refresh Index",
    callback = "RefreshIndex",
  })
  app.registerUi({
    menu = "⚙ Settings…",
    callback = "ShowSettings",
  })
  app.registerUi({
    menu = "📍 Use Current Document Folder as Root",
    callback = "UseCurrentDocumentFolder",
  })

  if state.config.root ~= "" and state.lastScanError == nil then
    register_tree_menu(state.tree, state.rootLabel)
  end
end

function OpenIndexedFile(mode)
  local entry = state.menuFiles[mode]
  if not entry then
    show_message("The selected menu entry is no longer available.", true)
    return
  end
  open_path(entry.path)
end

function ShowQuickOpen()
  show_quick_open_dialog()
end

function ShowBrowser()
  show_browser_dialog()
end

function RefreshIndex()
  local ok, err = rebuild_index()
  if not ok then
    show_message(err, true)
    return
  end
  refresh_notice()
end

function ShowSettings()
  show_settings_dialog()
end

function UseCurrentDocumentFolder()
  local folder = current_document_folder()
  if not folder then
    show_message("No open .xopp or PDF document is available.", true)
    return
  end

  local ok, err = set_root(folder)
  if not ok then
    show_message(err, true)
    return
  end

  refresh_notice()
end
