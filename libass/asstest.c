// Times native libass on the TV: renders every frame of a time range at 1920x1080 and blends
// the bitmaps into an RGBA buffer, like a player would. Prints per-frame render and blend times.
// usage: asstest <file.ass> <fontdir> <start_s> <end_s> [fps]
#include <ass/ass.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static int cmp(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static void blend(unsigned char *dst, int W, int H, ASS_Image *img) {
    for (; img; img = img->next) {
        unsigned r = img->color >> 24, g = (img->color >> 16) & 255, b = (img->color >> 8) & 255;
        unsigned a = 255 - (img->color & 255);
        for (int y = 0; y < img->h; y++) {
            int dy = img->dst_y + y;
            if (dy < 0 || dy >= H) continue;
            const unsigned char *src = img->bitmap + y * img->stride;
            unsigned char *row = dst + (size_t)dy * W * 4;
            for (int x = 0; x < img->w; x++) {
                int dx = img->dst_x + x;
                if (dx < 0 || dx >= W) continue;
                unsigned k = src[x] * a / 255;
                if (!k) continue;
                unsigned char *p = row + dx * 4;
                p[0] = (r * k + p[0] * (255 - k)) / 255;
                p[1] = (g * k + p[1] * (255 - k)) / 255;
                p[2] = (b * k + p[2] * (255 - k)) / 255;
                p[3] = k + p[3] * (255 - k) / 255;
            }
        }
    }
}

int main(int argc, char **argv) {
    if (argc < 5) { fprintf(stderr, "usage: %s file.ass fontdir start end [fps]\n", argv[0]); return 1; }
    const int W = 1920, H = 1080;
    double start = atof(argv[3]), end = atof(argv[4]), fps = argc > 5 ? atof(argv[5]) : 23.976;

    double t0 = now_ms();
    ASS_Library *lib = ass_library_init();
    ass_set_fonts_dir(lib, argv[2]);
    ass_set_extract_fonts(lib, 1);
    ASS_Renderer *r = ass_renderer_init(lib);
    ass_set_frame_size(r, W, H);
    ass_set_storage_size(r, W, H);
    ass_set_fonts(r, "/usr/share/fonts/DroidSans.ttf", "sans-serif", ASS_FONTPROVIDER_NONE, NULL, 0);
    ASS_Track *track = ass_read_file(lib, argv[1], NULL);
    if (!track) { fprintf(stderr, "could not read %s\n", argv[1]); return 1; }
    printf("libass %#x, load %.0f ms, %d events\n", ass_library_version(), now_ms() - t0, track->n_events);

    int n = (int)((end - start) * fps);
    double *rt = malloc(n * sizeof *rt), *bt = malloc(n * sizeof *bt);
    unsigned char *frame = malloc((size_t)W * H * 4);
    long images = 0, pixels = 0;
    for (int i = 0; i < n; i++) {
        long long ms = (long long)((start + i / fps) * 1000);
        int changed;
        double a = now_ms();
        ASS_Image *img = ass_render_frame(r, track, ms, &changed);
        double b = now_ms();
        memset(frame, 0, (size_t)W * H * 4);
        blend(frame, W, H, img);
        double c = now_ms();
        rt[i] = b - a; bt[i] = c - b;
        for (ASS_Image *p = img; p; p = p->next) { images++; pixels += (long)p->w * p->h; }
    }
    double worst = 0, worst_at = 0;
    for (int i = 0; i < n; i++) if (rt[i] + bt[i] > worst) { worst = rt[i] + bt[i]; worst_at = start + i / fps; }
    qsort(rt, n, sizeof *rt, cmp); qsort(bt, n, sizeof *bt, cmp);
    printf("frames %d  render ms median %.2f p95 %.2f max %.2f | blend ms median %.2f p95 %.2f max %.2f\n",
           n, rt[n / 2], rt[n * 95 / 100], rt[n - 1], bt[n / 2], bt[n * 95 / 100], bt[n - 1]);
    printf("worst frame %.1f ms at %.2f s, avg %.1f images and %.0f kpx per frame\n",
           worst, worst_at, (double)images / n, pixels / 1000.0 / n);
    return 0;
}
