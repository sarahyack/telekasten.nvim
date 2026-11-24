local config = require("telekasten.config")
local Path = require("plenary.path")
local scan = require("plenary.scandir")

local M = {}

-- Prefer the longest configured suffix (e.g. .note.md before .md).
function M.suffix(name)
    local suffix
    for _, ext in ipairs(config.options.note_extensions or {}) do
        if vim.endswith(name, ext) and (not suffix or #ext > #suffix) then
            suffix = ext
        end
    end
    return suffix
end

-- Qualify a collision with the vault-relative path, or the full path in another root.
local function qualified_path(path)
    local prefix = config.options.home:gsub("/$", "") .. "/"
    if vim.startswith(path, prefix) then
        return "./" .. path:sub(#prefix + 1)
    end
    return path
end

-- A recursive grep only needs each outermost note directory once.
function M.search_roots()
    local roots = require("telekasten.utils.files").assemble_roots({
        include_aux = false,
    })
    for i, root in ipairs(roots) do
        roots[i] = vim.fn.simplify(root .. "/.")
    end
    table.sort(roots)
    local dirs = {}
    for _, root in ipairs(roots) do
        local covered = false
        for _, dir in ipairs(dirs) do
            if
                root == dir or vim.startswith(root, dir:gsub("/$", "") .. "/")
            then
                covered = true
                break
            end
        end
        if not covered then
            table.insert(dirs, root)
        end
    end
    return dirs
end

-- Index both qualified and bare link targets, keeping every matching file.
function M.index()
    local targets, files = {}, {}
    local function add(title, path)
        targets[title] = targets[title] or {}
        if not vim.tbl_contains(targets[title], path) then
            table.insert(targets[title], path)
        end
    end

    for _, root in
        ipairs(require("telekasten.utils.files").assemble_roots({
            include_aux = false,
        }))
    do
        root = vim.fn.simplify(root .. "/.")
        for _, entry in ipairs(scan.scan_dir(root)) do
            local path = vim.fn.simplify(entry)
            local ext = M.suffix(path)
            if ext then
                files[path] = true
                add(path, path)
                local prefix = root:sub(-1) == "/" and root or root .. "/"
                local relative = path:sub(#prefix + 1)
                if root == config.options.home then
                    add("./" .. relative, path)
                    add("./" .. relative:sub(1, -#ext - 1), path)
                end
                for _, name in ipairs({
                    relative,
                    vim.fn.fnamemodify(path, ":t"),
                }) do
                    add(name, path)
                    add(name:sub(1, -#ext - 1), path)
                end
            end
        end
    end
    return targets, files
end

function M.link_title(stem, ext, targets, path)
    local function identifies(title)
        local matches = targets[title]
        return matches and #matches == 1 and matches[1] == path
    end
    if ext == config.options.extension and identifies(stem) then
        return stem
    end
    if identifies(stem .. ext) then
        return stem .. ext
    end
    -- Allow a typed title in the insert-link picker to name a future note.
    if not targets[path] and not targets[stem] then
        return ext == config.options.extension and stem or stem .. ext
    end
    return qualified_path(path)
end

-- Return the spellings that unambiguously refer to this one note.
function M.unique_titles(targets, path)
    local titles = {}
    for title, matches in pairs(targets) do
        if #matches == 1 and matches[1] == path then
            table.insert(titles, title)
        end
    end
    table.sort(titles)
    return titles
end

-- Keep the original heading or alias, including the spacing around its separator.
function M.split_link(link)
    local target, tail = link:match("^([^#|]-)(%s*[#|].*)$")
    return target or link, tail or ""
end

local function replace_links(lines, replacements)
    local changed = false
    for i, line in ipairs(lines) do
        local new = line:gsub("%[%[([^%]\n]+)%]%]", function(link)
            local target, tail = M.split_link(link)
            if replacements[target] then
                return "[[" .. replacements[target] .. tail .. "]]"
            end
        end)
        if new ~= line then
            lines[i] = new
            changed = true
        end
    end
    return changed
end

-- Prepare every affected disk file and loaded buffer before moving the source.
local function prepare_links(old_path, new_path)
    local targets, files = M.index()
    local ext = M.suffix(new_path)
    local qualified = qualified_path(new_path)
    local relative = qualified:gsub("^%./", "")
    local replacements = {}
    local function collides(name)
        for _, path in ipairs(targets[name] or {}) do
            if path ~= old_path then
                return true
            end
        end
        return false
    end
    for _, old in ipairs(M.unique_titles(targets, old_path)) do
        if Path:new(old):is_absolute() then
            replacements[old] = new_path
        elseif vim.startswith(old, "./") then
            replacements[old] = qualified
        else
            local name = old:find("/", 1, true) and relative
                or vim.fn.fnamemodify(new_path, ":t")
            local stem = name:sub(1, -#ext - 1)
            if
                not M.suffix(old)
                and not Path:new(name):is_absolute()
                and ext == config.options.extension
                and not collides(stem)
            then
                name = stem
            end
            replacements[old] = collides(name) and qualified or name
        end
    end

    local changes = {}
    local function record(path, buf, before)
        local after = vim.deepcopy(before)
        if replace_links(after, replacements) then
            if buf then
                assert(vim.bo[buf].modifiable, "Cannot update buffer " .. path)
            else
                assert(
                    vim.fn.filewritable(path) == 1,
                    "Cannot update file " .. path
                )
            end
            table.insert(changes, {
                path = path,
                buf = buf,
                before = before,
                after = after,
                modified = buf and vim.bo[buf].modified,
            })
        end
    end
    for path in pairs(files) do
        record(path, nil, vim.fn.readfile(path, "b"))
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        local path = vim.api.nvim_buf_get_name(buf)
        if files[path] and vim.api.nvim_buf_is_loaded(buf) then
            record(path, buf, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        end
    end
    return changes
end

local function write_change(change, lines)
    if change.buf then
        vim.api.nvim_buf_set_lines(change.buf, 0, -1, false, lines)
        vim.bo[change.buf].modified = change.modified
    else
        assert(
            vim.fn.writefile(lines, change.path, "b") == 0,
            "Could not update " .. change.path
        )
    end
end

function M.rename(old_path, new_path)
    local changes = config.options.rename_update_links
            and prepare_links(old_path, new_path)
        or {}
    local applied = 0
    local buf = vim.api.nvim_get_current_buf()
    local modified = vim.bo[buf].modified
    assert(
        vim.fn.getftype(new_path) == "",
        "Destination already exists: " .. new_path
    )
    local saved = false
    local ok, err = pcall(function()
        for i, change in ipairs(changes) do
            if not change.buf then
                assert(
                    vim.deep_equal(
                        vim.fn.readfile(change.path, "b"),
                        change.before
                    ),
                    "File changed during rename: " .. change.path
                )
            end
            applied = i
            write_change(change, change.after)
        end
        vim.cmd("saveas " .. vim.fn.fnameescape(new_path))
        saved = true
        local alternate = vim.fn.bufnr(old_path)
        if alternate ~= -1 and alternate ~= buf then
            vim.api.nvim_buf_delete(alternate, {})
        end
        assert(os.remove(old_path))
    end)
    if not ok then
        -- :saveas may change the buffer name and write the destination before
        -- an autocmd raises. Restore the observed state in either case.
        if saved or vim.api.nvim_buf_get_name(buf) == new_path then
            local alternate = vim.fn.bufnr(old_path)
            if alternate ~= -1 and alternate ~= buf then
                vim.api.nvim_buf_delete(alternate, {})
            end
            vim.api.nvim_buf_call(buf, function()
                vim.cmd(
                    "silent noautocmd keepalt file "
                        .. vim.fn.fnameescape(old_path)
                )
            end)
            if vim.fn.getftype(new_path) == "file" then
                assert(os.remove(new_path))
            end
            vim.bo[buf].modified = modified
        end
        for i = applied, 1, -1 do
            write_change(changes[i], changes[i].before)
        end
        error(err)
    end
end

return M
