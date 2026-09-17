local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local GuiService = game:GetService("GuiService")
local VirtualUser = game:GetService("VirtualUser")
local RunService = game:GetService("RunService")

local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()
local localPlayer = Players.LocalPlayer

local autoTeleportActive = false
local autoDepositActive = false
local autoTrialsActive = false
local autoRitualActive = false
local autoRejoinActive = true

local isTriggeringRitual = false
local isRitualOnCooldown = false
local depositInterval = 10
local ritualPosition = nil

local selectedOres = {}
local selectedMobs = {}

local tpThread = nil
local depositThread = nil
local trialsThread = nil
local ritualThread = nil

local mainRemote = ReplicatedStorage:WaitForChild("__Net"):WaitForChild("MainRemote")

-- === ANTI-AFK & AUTO-REJOIN ===
localPlayer.Idled:Connect(function()
    VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
    task.wait(1)
    VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
end)

GuiService.ErrorMessageChanged:Connect(function()
    if autoRejoinActive then
        task.wait(2)
        TeleportService:Teleport(game.PlaceId, localPlayer)
    end
end)

local function teleportToCFrame(targetCFrame)
    local character = localPlayer.Character
    local hrp = character and character:FindFirstChild("HumanoidRootPart")
    if hrp then
        hrp.CFrame = targetCFrame * CFrame.new(0, 0, 3)
    end
end

-- === AUTO RITUAL LOGIKA ===
local function startAutoRitual()
    ritualThread = task.spawn(function()
        while autoRitualActive do
            if not isRitualOnCooldown then
                local character = localPlayer.Character
                local hrp = character and character:FindFirstChild("HumanoidRootPart")

                if hrp then
                    local targetCFrame = ritualPosition or hrp.CFrame

                    isTriggeringRitual = true
                    isRitualOnCooldown = true

                    hrp.CFrame = targetCFrame
                    task.wait(1.5)

                    pcall(function()
                        mainRemote:FireServer("StartRitual")
                    end)

                    Rayfield:Notify({
                        Title = "Ritualas Aktyvuotas!",
                        Content = "StartRitual paleistas. Auto TP grąžintas!",
                        Duration = 3
                    })

                    task.wait(1.0)
                    isTriggeringRitual = false

                    task.wait(177.5)
                    isRitualOnCooldown = false
                end
            end
            task.wait(1)
        end
    end)
end

-- === AUTO TRIALS LOGIKA (IŠFILTRUOTI PICKUP IR ENTER OBJEKTAI) ===
local function startAutoTrials()
    trialsThread = task.spawn(function()
        local debugSent = false

        while autoTrialsActive do
            if not isTriggeringRitual then
                local character = localPlayer.Character
                local hrp = character and character:FindFirstChild("HumanoidRootPart")

                if hrp then
                    local mobList = {}

                    -- Tikriname visus Trial kambarius
                    for _, descendant in ipairs(workspace:GetDescendants()) do
                        if descendant.Name:find("TrialRoom") or descendant.Name:find("Trial") then
                            for _, child in ipairs(descendant:GetDescendants()) do
                                local nameLower = child.Name:lower()
                                local isPlayer = child.Name == localPlayer.Name
                                
                                -- Ignoruojame portalus, įėjimus ir pickupus
                                local isIgnored = nameLower:find("enter") 
                                               or nameLower:find("pickup") 
                                               or nameLower:find("portal") 
                                               or nameLower:find("door") 
                                               or nameLower:find("leave")
                                               or nameLower:find("button")

                                if not isIgnored and not isPlayer then
                                    -- Tikriname ar tai mobas: turi UI/Health BAR arba Humanoid
                                    local hasUI = child:FindFirstChildOfClass("BillboardGui") or child:FindFirstChild("OresTopUI") or child:FindFirstChild("TopUI", true)
                                    local hasHumanoid = child:FindFirstChildOfClass("Humanoid")
                                    
                                    if hasUI or hasHumanoid then
                                        local part = child:IsA("BasePart") and child or child:FindFirstChild("HumanoidRootPart") or child:FindFirstChildOfClass("BasePart")
                                        if part then
                                            table.insert(mobList, part)
                                        end
                                    end
                                end
                            end
                        end
                    end

                    if not debugSent then
                        debugSent = true
                        Rayfield:Notify({
                            Title = "Trials Debug",
                            Content = "Tikrų Mobų (bez Pickup): " .. #mobList,
                            Duration = 5
                        })
                    end

                    -- Teleportacija per atrinktus mobus
                    if #mobList > 0 then
                        for _, mobPart in ipairs(mobList) do
                            if not autoTrialsActive or isTriggeringRitual then break end

                            if mobPart and mobPart.Parent then
                                hrp.CFrame = mobPart.CFrame * CFrame.new(0, 0, 3)
                                task.wait(0.15)
                            end
                        end
                    else
                        task.wait(0.5)
                    end
                end
            else
                task.wait(0.5)
            end
            task.wait(0.05)
        end
    end)
end

-- === RAYFIELD UI ===
local Window = Rayfield:CreateWindow({
   Name = "VX Hub",
   Icon = 0,
   LoadingTitle = "VX Hub Kraunasi...",
   LoadingSubtitle = "by Sirius Rayfield",
   Theme = "Default",
   DisableRayfieldPrompts = false,
   ConfigurationSaving = {
      Enabled = true,
      FolderName = "VXHubConfigs",
      FileName = "VX_Config"
   }
})

local MainTab = Window:CreateTab("Teleport", 4483362458)
local TrialsTab = Window:CreateTab("Trials", 4483362458)
local AutomationTab = Window:CreateTab("Automation", 4483362458)

TrialsTab:CreateSection("🏆 Auto Trials (Teleport Cleaver)")

TrialsTab:CreateToggle({
   Name = "Auto TP To Wave Mobs",
   CurrentValue = false,
   Flag = "AutoTrialsToggle",
   Callback = function(Value)
       autoTrialsActive = Value
       if autoTrialsActive then 
           startAutoTrials()
       else 
           if trialsThread then task.cancel(trialsThread) trialsThread = nil end 
       end
   end,
})

TrialsTab:CreateButton({
   Name = "🔍 Tikrinti Trial Mobų Aplankus (Test)",
   Callback = function()
       local count = 0
       local names = {}
       for _, descendant in ipairs(workspace:GetDescendants()) do
           if descendant.Name == "Mobs" and descendant.Parent and descendant.Parent.Name:find("Trial") then
               count = count + 1
               table.insert(names, descendant.Parent.Name)
           end
       end
       Rayfield:Notify({
           Title = "Rankinė Paieška",
           Content = "Trial aplankų: " .. count .. " (" .. table.concat(names, ", ") .. ")",
           Duration = 6
       })
   end,
})

AutomationTab:CreateSection("🔮 Auto Ritual")

AutomationTab:CreateButton({
   Name = "Nustatyti Dabartinę Vietą kaip Ritualo Vietą",
   Callback = function()
       local hrp = localPlayer.Character and localPlayer.Character:FindFirstChild("HumanoidRootPart")
       if hrp then
           ritualPosition = hrp.CFrame
           Rayfield:Notify({ Title = "Ritualo Vieta", Content = "Dabartinė pozicija išsaugota ritualams!", Duration = 3 })
       end
   end,
})

AutomationTab:CreateToggle({
   Name = "Auto Start Ritual (Loop Every 3m)",
   CurrentValue = false,
   Flag = "AutoRitualToggle",
   Callback = function(Value)
       autoRitualActive = Value
       if autoRitualActive then
           startAutoRitual()
       else
           isTriggeringRitual = false
           isRitualOnCooldown = false
           if ritualThread then task.cancel(ritualThread) ritualThread = nil end
       end
   end,
})
