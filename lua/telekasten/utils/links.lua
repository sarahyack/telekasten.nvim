local M = {}
package.loaded[...] = M

local scan = require("plenary.scandir")
local config = require("telekasten.config")
local tkutils = require("telekasten.utils")
local fileutils = require("telekasten.utils.files")

local vim = vim

local function file_exists(fn, file_list)
    return file_list[fn] ~= nil
end

local function resolve_link(title, file_list, subdir_list, opts)
    local fexists = false
    local filename = title .. opts.extension
    filename = filename:gsub("^%./", "") -- strip potential leading ./

    local roots = fileutils.assemble_roots({ include_aux = false })

    -- check all known common roots, excluding templates & images
    for _, root in ipairs(roots) do
        local tempfn = root .. "/" .. filename
        if file_exists(tempfn, file_list) then
            filename = tempfn
            fexists = true
            break
        end
    end

    if fexists == false then
        -- now search for it in all subdirs
        local tempfn
        for _, folder in pairs(subdir_list) do
            tempfn = folder .. "/" .. filename
            -- [[testnote]]
            if file_exists(tempfn, file_list) then
                filename = tempfn
                fexists = true
                -- print("Found: " .. filename)
                break
            end
        end
    end

    if fexists == false then
        -- default fn for creation
        filename = opts.home .. "/" .. filename
    end

    return fexists, filename
end

-- TODO: cache mtimes and only update if changed

-- The reason we go over all notes in one go, is: backlinks
-- We generate 2 maps: one containing the number of links within a note
--    and a second one containing the number of backlinks to a note
-- Since we're parsing all notes anyway, we can mark linked notes as backlinked from the currently parsed note
M.generate_backlink_map = function(opts)
    assert(opts ~= nil, "opts must not be nil")
    -- TODO: check for code blocks
    -- local in_fenced_code_block = false
    -- also watch out for \t tabbed code blocks or ones with leading spaces that don't end up in a - or * list

    -- first, find all notes
    assert(opts.extension ~= nil, "Error: need extension in opts!")
    assert(opts.home ~= nil, "Error: need home dir in opts!")

    -- async seems to have lost await and we don't want to enter callback hell, hence we go sync here
    local subdir_list = scan.scan_dir(opts.home, { only_dirs = true })
    local file_list = {}
    -- transform the file list
    local _x = scan.scan_dir(opts.home, {
        search_pattern = function(entry)
            return entry:sub(-#opts.extension) == opts.extension
        end,
    })
    for _, v in pairs(_x) do
        file_list[v] = true
    end

    -- now process all the notes
    local link_counts = {}
    local backlink_counts = {}
    for note_fn, _ in pairs(file_list) do
        -- print("processing " .. note_fn .. "...")
        -- go over file line by line
        for line in io.lines(note_fn) do
            for linktitle in line:gmatch("%[%[(.-)%]%]") do
                -- strip # from title
                linktitle = linktitle:gsub("#.*$", "")

                -- now: inc our link count
                link_counts[note_fn] = link_counts[note_fn] or 0
                link_counts[note_fn] = link_counts[note_fn] + 1

                -- and: inc the backlinks of the linked note
                local fexists, backlinked_file =
                    resolve_link(linktitle, file_list, subdir_list, opts)
                -- print(
                --     "note for link `"
                --         .. linktitle
                --         .. "` = "
                --         .. backlinked_file
                --         .. " (exists: "
                --         .. tostring(fexists)
                --         .. ')'
                -- )
                if fexists and (note_fn ~= backlinked_file) then
                    backlink_counts[backlinked_file] = backlink_counts[backlinked_file]
                        or 0
                    backlink_counts[backlinked_file] = backlink_counts[backlinked_file]
                        + 1
                end
            end
        end

        -- check if in comments block
        -- find all links in the note and count them
        -- add 1 (this note) as back-link to linked note
    end
    local ret = {
        link_counts = link_counts,
        backlink_counts = backlink_counts,
    }
    return ret
end

-- Remove alias in links to get only link part
-- [[my_cool_link | My Alias]] -> "my_cool_link"
--
function M.remove_alias(link)
    local split_index = string.find(link, "%s*|")
    if split_index ~= nil and type(split_index) == "number" then
        return string.sub(link, 0, split_index - 1)
    end
    return link
end

--- follow_url(url)
-- Passes the given URL to the OS's tool for handling and opening URLs
-- @param url string URL for an external resource
function M.follow_url(url)
    if config.options.follow_url_fallback then
        local cmd =
            string.gsub(config.options.follow_url_fallback, "{{url}}", url)
        return vim.cmd(cmd)
    end

    -- we just leave it to the OS's handler to deal with what kind of URL it is
    local function format_command(cmd)
        return 'call jobstart(["'
            .. cmd
            .. '", "'
            .. url
            .. '"], {"detach": v:true})'
    end

    -- Choose OS-appropriate command and run it if possible
    local command
    if vim.fn.has("mac") == 1 then
        command = format_command("open")
        vim.cmd(command)
    elseif vim.fn.has("unix") then
        command = format_command("xdg-open")
        vim.cmd(command)
    else
        print("Cannot open URLs on your operating system") -- TODO: Figure out how to do this on Windows
    end
end

-- Use ripgrep's existing Markdown and ignore rules for both copies of a note.
local function markdown_paths(roots, needle)
    local cmd = { "rg", "--null", "--type", "markdown" }
    vim.list_extend(
        cmd,
        needle and { "--files-with-matches", "--fixed-strings", "--", needle }
            or { "--files", "--" }
    )
    local output = vim.fn.systemlist(vim.list_extend(cmd, roots), "", 1)
    assert(
        vim.v.shell_error <= 1,
        "Could not find notes: " .. table.concat(output, "\n")
    )
    -- systemlist represents the NUL after each filename as a newline within an item.
    for i, line in ipairs(output) do
        output[i] = line:gsub("\n", "\0")
    end
    local paths = {}
    for path in table.concat(output, "\n"):gmatch("[^%z]+") do
        paths[vim.fn.simplify(path)] = true
    end
    return paths
end

-- A backlink on disk and in a loaded buffer can have different text.
-- Prepare each edit against the version it will actually update.
local function backlink_changes(oldname, newname)
    local changes = {}
    local pattern = "%[%[" .. tkutils.escape(oldname) .. "(%s*[]#|])"
    local function record(path, buf, before)
        local after
        for i, line in ipairs(before) do
            local updated = line:gsub(pattern, function(tail)
                return "[[" .. newname .. tail
            end)
            if updated ~= line then
                after = after or vim.list_slice(before)
                after[i] = updated
            end
        end
        if after then
            assert(
                buf and vim.bo[buf].modifiable
                    or not buf and vim.fn.filewritable(path) == 1,
                "Cannot update backlinks in " .. path
            )
            table.insert(changes, {
                path = path,
                buf = buf,
                before = before,
                after = after,
                modified = buf and vim.bo[buf].modified,
            })
        end
    end

    local roots = {}
    for _, dir in ipairs(fileutils.assemble_roots({ include_aux = false })) do
        if vim.fn.isdirectory(dir) == 1 then
            table.insert(roots, vim.fn.fnamemodify(dir, ":p"))
        end
    end
    if #roots == 0 then
        return changes
    end
    for path in pairs(markdown_paths(roots, "[[" .. oldname)) do
        record(path, nil, vim.fn.readfile(path, "b"))
    end
    -- A link may exist only in memory, even in a note awaiting its first save.
    local notes = markdown_paths(roots)
    for _, info in ipairs(vim.fn.getbufinfo({ bufloaded = 1 })) do
        local path = info.name
        if
            vim.bo[info.bufnr].buftype == ""
            and vim.endswith(path, config.options.extension)
            and vim.fn.getftype(path) == ""
        then
            for _, root in ipairs(roots) do
                if vim.startswith(path, root) then
                    notes[path] = true
                    break
                end
            end
        end
        if notes[path] then
            record(
                path,
                info.bufnr,
                vim.api.nvim_buf_get_lines(info.bufnr, 0, -1, false)
            )
        end
    end
    return changes
end

local function write_change(change, lines)
    if change.buf then
        for i, line in ipairs(lines) do
            if change.before[i] ~= change.after[i] then
                vim.api.nvim_buf_set_lines(
                    change.buf,
                    i - 1,
                    i,
                    false,
                    { line }
                )
            end
        end
        vim.bo[change.buf].modified = change.modified
    else
        assert(
            vim.fn.writefile(lines, change.path, "b") == 0,
            "Could not update " .. change.path
        )
    end
end

--- Update saved backlinks and loaded copies, preserving any unsaved edits.
--- When renaming a file, restore the links if the move fails.
function M.rename_update_links(oldfile, newname, move)
    local changes = config.options.rename_update_links
            and backlink_changes(oldfile.title, newname)
        or {}
    local applied = 0
    local ok, err = pcall(function()
        for i, change in ipairs(changes) do
            local current = change.buf
                    and vim.api.nvim_buf_get_lines(change.buf, 0, -1, false)
                or vim.fn.readfile(change.path, "b")
            assert(
                vim.deep_equal(current, change.before),
                "Note changed during rename: " .. change.path
            )
            applied = i
            write_change(change, change.after)
        end
        if move then
            move()
        end
    end)
    if not ok then
        for i = applied, 1, -1 do
            write_change(changes[i], changes[i].before)
        end
        error(err)
    end
end

--- make_relative_path
-- Return a relative path from the buffer to the image
-- @param bufferpath string Path to the buffer's open file
-- @param imagepath string Path to the desired image
-- @param sep string Directory separator for the local OS file paths, e.g., \ on Windows and / on Linux
-- @return string Relative path from the note open in the buffer to the given image at imagepath
-- TODO: Verify the exact values passed as bufferpath and imagepath. Are they to files or to directories?
function M.make_relative_path(bufferpath, imagepath, sep)
    sep = sep or "/" -- TODO: This seems UNIX-centric. Consider using something from os or plenary to get OS's file sep

    -- Split the buffer and image path into their dirs/files
    local buffer_dirs = {}
    for w in string.gmatch(bufferpath, "([^" .. sep .. "]+)") do
        buffer_dirs[#buffer_dirs + 1] = w
    end
    local image_dirs = {}
    for w in string.gmatch(imagepath, "([^" .. sep .. "]+)") do
        image_dirs[#image_dirs + 1] = w
    end

    -- The parts of the dir list that match won't matter, so skip them
    local i = 1
    while i < #image_dirs and i < #buffer_dirs do
        if image_dirs[i] ~= buffer_dirs[i] then
            break
        else
            i = i + 1
        end
    end

    -- Append ../ to walk up from the buffer location and the path downward
    -- to the location of the image file in order to create a relative path
    local relative_path = ""
    while i <= #image_dirs or i <= #buffer_dirs do
        if i <= #image_dirs then
            if relative_path == "" then
                relative_path = image_dirs[i]
            else
                relative_path = relative_path .. sep .. image_dirs[i]
            end
        end
        if i <= #buffer_dirs - 1 then
            relative_path = ".." .. sep .. relative_path
        end
        i = i + 1
    end

    return relative_path
end

return M
