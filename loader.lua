local Games = {
    [76911729991355] = "https://raw.githubusercontent.com/NeVoxxas/vxhub/main/vxhub.lua",
}

local currentPlaceId = game.PlaceId

if Games[currentPlaceId] then
    print("🎯 [VX Hub] Game recognized! Loading...")
    loadstring(game:HttpGet(Games[currentPlaceId]))()
else
    warn("⚠️ [VX Hub] Unrecognized game! (PlaceId: " .. tostring(currentPlaceId) .. ")")
end
