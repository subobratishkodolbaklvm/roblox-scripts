-- 1. ПОДКЛЮЧАЕМ БИБЛИОТЕКУ ИНТЕРФЕЙСА
local Library = loadstring(game:HttpGet("https://githubusercontent.com"))()

-- 2. СОЗДАЕМ ОКНО МЕНЮ (Тема Midnight)
local Window = Library.CreateLib("MY CUSTOM HUB", "Midnight")

-- 3. СОЗДАЕМ ВКЛАДКИ
local MainTab = Window:NewTab("Игрок")
local CombatTab = Window:NewTab("Фарм и Бой")

-- 4. СОЗДАЕМ СЕКЦИИ ВНУТРИ ВКЛАДОК
local MainSection = MainTab:NewSection("Характеристики и Визуал")
local TeleportSection = MainTab:NewSection("Телепортация")
local CombatSection = CombatTab:NewSection("Автоматизация")

-- ==========================================
-- ВКЛАДКА "ИГРОК" (ФУНКЦИИ СКОРОСТИ И ПРЫЖКА)
-- ==========================================

-- Кнопка увеличения скорости
MainSection:NewButton("Увеличить Скорость (Speed)", "Дает персонажу скорость 100", function()
    if game.Players.LocalPlayer.Character and game.Players.LocalPlayer.Character:FindFirstChild("Humanoid") then
        game.Players.LocalPlayer.Character.Humanoid.WalkSpeed = 100
    end
end)

-- Кнопка сброса скорости
MainSection:NewButton("Обычная Скорость", "Возвращает скорость к 16", function()
    if game.Players.LocalPlayer.Character and game.Players.LocalPlayer.Character:FindFirstChild("Humanoid") then
        game.Players.LocalPlayer.Character.Humanoid.WalkSpeed = 16
    end
end)

-- Слайдер высоты прыжка
MainSection:NewSlider("Высота прыжка", "Регулирует JumpPower", 300, 50, function(s)
    if game.Players.LocalPlayer.Character and game.Players.LocalPlayer.Character:FindFirstChild("Humanoid") then
        game.Players.LocalPlayer.Character.Humanoid.JumpPower = s
    end
end)

-- Кнопка включения ESP (ВХ)
MainSection:NewButton("Включить ESP (ВХ)", "Подсвечивает всех игроков силуэтами", function()
    for _, player in pairs(game.Players:GetPlayers()) do
        -- Подсвечиваем всех, кроме себя
        if player ~= game.Players.LocalPlayer and player.Character then
            -- Если подсветки еще нет, создаем её
            if not player.Character:FindFirstChild("EspHighlight") then
                local highlight = Instance.new("Highlight")
                highlight.Name = "EspHighlight"
                highlight.FillColor = Color3.fromRGB(255, 0, 0) -- Красный цвет заливки
                highlight.OutlineColor = Color3.fromRGB(255, 255, 255) -- Белая обводка
                highlight.FillTransparency = 0.5
                highlight.Parent = player.Character
            end
        end
    end
end)

-- ==========================================
-- ВКЛАДКА "ИГРОК" (СЕКЦИЯ ТЕЛЕПОРТА)
-- ==========================================

-- Кнопка телепорта к объекту
TeleportSection:NewButton("Телепорт к ShopPart", "Телепортирует к магазину (если он есть на карте)", function()
    -- Ищет в рабочей области деталь с именем ShopPart
    local target = workspace:FindFirstChild("ShopPart", true) 
    if target and target:IsA("BasePart") then
        if game.Players.LocalPlayer.Character and game.Players.LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then
            game.Players.LocalPlayer.Character.HumanoidRootPart.CFrame = target.CFrame
        end
    else
        -- Если объект не найден, выведет сообщение в консоль экзекутора
        print("Объект ShopPart не найден на карте! Измените имя в коде.")
    end
end)


-- ==========================================
-- ВКЛАДКА "ФАРМ И БОЙ" (АВТО-КЛИКЕР / АВТО-ФАРМ)
-- ==========================================

local autoClickActive = false -- Переменная, которая хранит статус переключателя

CombatSection:NewToggle("Авто-удар (Авто-фарм)", "Автоматически бьет оружием в руке", function(state)
    autoClickActive = state -- Присваиваем true (вкл) или false (выкл)
    
    -- Запускаем бесконечный цикл в отдельном потоке, чтобы игра не зависла
    task.spawn(function()
        while autoClickActive do
            -- Проверяем, жив ли персонаж и держит ли он предмет (Tool) в руках
            if game.Players.LocalPlayer.Character then
                local tool = game.Players.LocalPlayer.Character:FindFirstChildOfClass("Tool")
                if tool then
                    tool:Activate() -- Активируем (машем/стреляем) предметом
                end
            end
            task.wait(0.1) -- Пауза между ударами 0.1 секунды (можно изменить)
        end
    end)
end)
