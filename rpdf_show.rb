require 'gtk2'
require 'matrix'

def show_string(area, gc, x, y, str)
	win = area.window
	layout = Pango::Layout.new(area.pango_context)
	layout.text = str
	win.draw_layout(gc, x, y, layout)
end

def rpdf_show(doc, page)
	cont = page[-:Contents][].stream
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

	syms = doc.parse_contents(cont)
	user_mat = Matrix.I(3)
	line_mat = Matrix.I(3)
	main_mat = Matrix.I(3)
	stack = []

	area.signal_connect("expose_event") {|area, event|
		win = area.window
		gc = Gdk::GC.new(win)
		gc.background = white
		gc.foreground = black

		actions = {
			:cm => proc {|a,b,c,d,e,f|
				# spec p128 - S8.3.4 Transformation Matrices - note 2
				user_mat = Matrix.rows([[a, b, 0], [c, d, 0], [e, f, 1]]) *
								user_mat
				main_mat = line_mat * user_mat
			},
			:q => proc {
				stack << user_mat
			},
			:Q => proc {
				user_mat = stack.pop
				main_mat = line_mat * user_mat
			},
			:BT => proc {
				line_mat = Matrix.I(3)
				main_mat = user_mat
			},
			:Tm => proc {|a,b,c,d,e,f|
				line_mat = Matrix.rows([[a, b, 0], [c, d, 0], [e, f, 1]])
				main_mat = line_mat * user_mat
			},
			:Td => proc {|x,y|
				line_mat = Matrix.rows([line_mat.row(0), line_mat.row(1),
										[line_mat[2,0]+x, line_mat[2,1]+y, 1]])
				main_mat = line_mat * user_mat
			},
			:Tj => proc{|str|
				show_string(area, gc, main_mat[2,0], height-main_mat[2,1], str)
			},
			:TJ => proc{|array|
				str = array.map{|item|
					String === item ? item : ""
				}.join('')
				show_string(area, gc, main_mat[2,0], height-main_mat[2,1], str)
			},
		}

		syms.each_with_index{|sym, idx|
			action = actions[sym]
			if action && idx >= action.arity
				action.call(*syms[idx-action.arity...idx])
			end
		}
	}

	window.add(area)
	window.show_all
	Gtk.main
end
