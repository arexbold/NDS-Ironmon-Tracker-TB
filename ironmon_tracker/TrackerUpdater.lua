local function TrackerUpdater(initialSettings)
    local self = {}
    local settings = initialSettings
    local lastDayChecked = settings.automaticUpdates.LAST_DAY_CHECKED

    local currentVersion = {
        major = 0,
        minor = 0,
        patch = 0
    }

    local latestVersion = {
        major = 0,
        minor = 0,
        patch = 0
    }

    function self.getNewestVersionString()
        return latestVersion.major .. "." .. latestVersion.minor .. "." .. latestVersion.patch
    end

    local function runBatchCommand()
        local archiveName = "TripleBondTracker-main.tar.gz"
        local folderName = "TripleBondTracker-main"

        local TAR_URL = "https://github.com/arexbold/TripleBondTracker/archive/main.tar.gz"

        -- Each individual command listed in order, to be appended together later
        local batchCommands = {}
        if Paths.SLASH == "\\" then
            -- Windows version
            batchCommands = {
                "(echo Downloading the latest NDS Ironmon Tracker version.",
                string.format('curl -L "%s" -o "%s" --ssl-no-revoke', TAR_URL, archiveName),
                "echo; && echo Extracting downloaded files.",
                string.format('tar -xzf "%s"', archiveName),
                string.format('del "%s"', archiveName),
                "echo; && echo Applying the update; copying over files.",
                string.format('rmdir "%s\\.vscode" /s /q', folderName),
                string.format('del "%s\\.editorconfig" /q', folderName),
                string.format('del "%s\\.gitattributes" /q', folderName),
                string.format('del "%s\\.gitignore" /q', folderName),
                string.format('del "%s\\README.md" /q', folderName),
                string.format('xcopy "%s" /s /y /q /c', folderName),
                string.format('rmdir "%s" /s /q', folderName),
                "echo; && echo Version update completed successfully.",
                "timeout /t 3) || pause" -- Pause if any of the commands fail, those grouped between ( )
            }
        else
            -- Linux version
            batchCommands = {
                "echo Downloading the latest NDS Ironmon Tracker version.",
                string.format('curl -L "%s" -o "%s" --ssl-no-revoke', TAR_URL, archiveName),
                "echo && echo Extracting downloaded files.",
                string.format('tar -xzf "%s"', archiveName),
                string.format('rm "%s"', archiveName),
                'echo && echo "Applying the update; copying over files."',
                string.format('rm -r "%s/.vscode"', folderName),
                string.format('rm "%s/.editorconfig"', folderName),
                string.format('rm "%s/.gitattributes"', folderName),
                string.format('rm "%s/.gitignore"', folderName),
                string.format('rm "%s/README.md"', folderName),
                string.format('cp -rf "%s/." .', folderName),
                string.format('rm -r "%s"', folderName),
                "echo && echo Version update completed successfully."
            }
        end

        local combined_cmd = table.concat(batchCommands, " && ")

        print(string.format("Installing upgrade to version " .. self.getNewestVersionString() .. "."))

        local result = os.execute(combined_cmd)
        if not (result == true or result == 0) then
            print("Error trying to install: Unable to download, extract, or overwrite files properly.")
            return false
        end

        print("Update completed successfully.")
        return true
    end

    local function isOnLatestVersion()
        return (currentVersion.major * 10000 + currentVersion.minor * 100 + currentVersion.patch) >=
            (latestVersion.major * 10000 + latestVersion.minor * 100 + latestVersion.patch)
    end

    local function parseVersionNumber(versionString)
        if versionString == nil then
            return MiscUtils.deepCopy(currentVersion)
        end
        local major, minor, patch = string.match(versionString, "(%d+)%.(%d+)%.(%d+)")
        local versionTable = {
            ["major"] = tonumber(major),
            ["minor"] = tonumber(minor),
            ["patch"] = tonumber(patch)
        }
        return versionTable
    end

    local function updateLatestVersion()
        local versionURL = "https://api.github.com/repos/arexbold/TripleBondTracker/releases"
        local command = "curl " .. versionURL .. " --ssl-no-revoke"
        local response = MiscUtils.runExecuteCommand(command)
        if response ~= nil and response ~= "" then
            -- Get the first release (most recent, including pre-releases)
            local latestVersionString = string.match(response, '"tag_name":.*"v?(%d+%.%d+%.%d+)"')
            latestVersion = parseVersionNumber(latestVersionString)
        end
    end

    function self.updateExists()
        updateLatestVersion()
        settings.automaticUpdates.LAST_DAY_CHECKED = os.date("%x")
        return not isOnLatestVersion()
    end

    function self.alreadyCheckedForTheDay()
        local lastDay = settings.automaticUpdates.LAST_DAY_CHECKED
        local currentDay = os.date("%x")
        return currentDay == lastDay
    end

    function self.prepareForUpdate()
        DrawingUtils.canDrawImages = false
        emu.frameadvance()
        gui.clearImageCache()
        emu.frameadvance()
    end

    function self.downloadUpdate()
        local wasSoundOn = client.GetSoundOn()
        client.SetSoundOn(false)

        -- Additional safety check to help reduce chance of cached image locks
        self.prepareForUpdate()

        -- Finally, allow images again and perform the update (this order is intentional)
        DrawingUtils.canDrawImages = true
        local success = runBatchCommand()

        if client.GetSoundOn() ~= wasSoundOn then
            client.SetSoundOn(wasSoundOn)
        end

        return success
    end

    currentVersion = parseVersionNumber(MiscConstants.TRACKER_VERSION)

    return self
end

return TrackerUpdater
