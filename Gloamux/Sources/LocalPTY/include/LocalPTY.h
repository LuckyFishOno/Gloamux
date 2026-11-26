int gloamux_spawn(const char *shell, const char *directory, int rows, int columns, int *descriptor);
int gloamux_spawn_command(const char *path, char *const arguments[], const char *directory, char *const environment[], int rows, int columns, int *descriptor);
void gloamux_resize(int descriptor, int rows, int columns, int width, int height);
void gloamux_stop(int pid);
