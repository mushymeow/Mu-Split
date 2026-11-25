function love.conf(t)
  t.identity = "musplit"
  t.window.title = "Mu Split"
  t.window.width = 400
  t.window.height = 620
  t.window.resizable = true
  t.window.minwidth = 300
  t.window.minheight = 360
  t.window.vsync = 1
  t.window.msaa = 4
  t.window.highdpi = true
  t.modules.physics = false
  t.modules.joystick = false
  t.modules.video = false
end
