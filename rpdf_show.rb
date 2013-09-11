require 'gtk2'

def show_string(area, gc, x, y, str)
	win = area.window
	layout = Pango::Layout.new(area.pango_context)
	layout.text = str
	win.draw_layout(gc, x, y, layout)
end

def rpdf_show(doc, page)
	cont = page[-:Contents]
	res = page[-:Resources]
	box = page[-:MediaBox]

	width = box[2] - box[0]
	height = box[3] - box[1]

	window = Gtk::Window.new
	area = Gtk::DrawingArea.new
	area.set_size_request(width, height)
	white = Gdk::Color.new(0xffff, 0xffff, 0xffff)
	black = Gdk::Color.new(0, 0, 0)

	Gtk::StateType.constants.each{|c|
		area.modify_bg(Gtk::StateType.const_get(c), white)
	}

	area.signal_connect("expose_event") {|area, event|
		win = area.window
		gc = Gdk::GC.new(win)
		gc.background = white
		gc.foreground = black

		show_string(area, gc, 30, 30, "foobar")
	}

	window.add(area)
	window.show_all
	Gtk.main
end
