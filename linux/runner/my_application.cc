#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "scrup");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "scrup");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  // Impeller (default en Linux desde Flutter 3.47) dibuja los círculos con
  // SDFs y su anti-aliasing está roto: bordes de sierra visibles en
  // ClipOval/CircleBorder/borders redondeados (flutter#183083, #183418).
  // Volver a Skia, que rasteriza curvas con AA analítico sin dientes.
  fl_dart_project_set_enable_impeller(project, FALSE);

  // Icono de la ventana: se carga desde los assets de Flutter (app-logo.png)
  // y se reduce a 256px para que la carga sea ligera. Best-effort: si el
  // archivo no existe, el gestor de ventanas usa su icono por defecto.
  // El pragma evita que un warning de deprecación rompa el build con -Werror.
  const gchar* assets_path = fl_dart_project_get_assets_path(project);
  if (assets_path != nullptr) {
    g_autofree gchar* icon_path =
        g_build_filename(assets_path, "assets", "app-logo.png", nullptr);
    g_autoptr(GError) icon_error = nullptr;
    g_autoptr(GdkPixbuf) icon_full =
        gdk_pixbuf_new_from_file(icon_path, &icon_error);
    if (icon_full != nullptr) {
      GdkPixbuf* icon = gdk_pixbuf_scale_simple(icon_full, 256, 256,
                                                GDK_INTERP_BILINEAR);
      if (icon != nullptr) {
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
        gtk_window_set_icon(window, icon);
#pragma GCC diagnostic pop
        g_object_unref(icon);
      }
    }
  }

  FlView* view = fl_view_new(project);

  // Fondo del view TRANSPARENTE para poder redondear las esquinas inferiores
  // de la ventana desde Flutter (ClipRRect en main.dart): donde la app no
  // pinta, se ve el escritorio a través de la ventana. Solo cuando el
  // escritorio compone (Wayland siempre; X11 con compositor activo): sin
  // compositor el alpha se ignora y un fondo transparente dejaría basura,
  // así que se mantiene negro opaco (esquinas cuadradas, como siempre).
  // El fondo de la VENTANA también se hace transparente, o el tema de GTK
  // pintaría un rectángulo opaco detrás del view en las esquinas recortadas.
  GdkScreen* wscreen = gdk_screen_get_default();
  gboolean composited =
      wscreen != nullptr && gdk_screen_is_composited(wscreen);
  GdkRGBA background_color;
  gdk_rgba_parse(&background_color, composited ? "#00000000" : "#000000");
  fl_view_set_background_color(view, &background_color);
  if (composited) {
    GdkRGBA transparent;
    gdk_rgba_parse(&transparent, "#00000000");
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
    gtk_widget_override_background_color(GTK_WIDGET(window),
                                         GTK_STATE_FLAG_NORMAL, &transparent);
#pragma GCC diagnostic pop
  }

  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));
  // Registrar los plugins ANTES de mostrar el view (patrón recomendado para
  // ventanas transparentes): los plugins se enganchan a la ventana antes de
  // que se pinte el primer frame.
  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  gtk_widget_show(GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
