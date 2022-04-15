#include <AvailabilityMacros.h>
#include <Cocoa/Cocoa.h>

bool is_general_capture_available(void)
{
	return (NSClassFromString(@"SCStream") != NULL);
}

#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 120300 // __MAC_12_3
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

#include <stdlib.h>
#include <obs-module.h>
#include <util/threading.h>
#include <pthread.h>

#include <IOSurface/IOSurface.h>
#include <ScreenCaptureKit/ScreenCaptureKit.h>
#include <CoreMedia/CMSampleBuffer.h>
#include <CoreVideo/CVPixelBuffer.h>

#include "window-utils.h"

typedef enum {
	GeneralCaptureDisplayStream = 0,
	GeneralCaptureWindowStream = 1,
	GeneralCaptureApplicationStream = 2,
} GeneralCaptureStreamType;

@interface GeneralCaptureDelegate : NSObject <SCStreamOutput>

@property struct general_capture *dc;

@end

struct general_capture {
	obs_source_t *source;

	gs_samplerstate_t *sampler;
	gs_effect_t *effect;
	gs_texture_t *tex;
	gs_vertbuffer_t *vertbuf;

	NSRect frame;
	bool hide_cursor;

	SCStream *disp;
	SCShareableContent *shareable_content;
	GeneralCaptureDelegate *capture_delegate;

	os_event_t *disp_finished;
	os_event_t *stream_start_completed;
	os_sem_t *shareable_content_available;
	IOSurfaceRef current, prev;

	pthread_mutex_t mutex;

	unsigned capture_type;
	CGDirectDisplayID display;
	struct cocoa_window window;
	NSString *application_id;
};

static void destroy_general_stream(struct general_capture *dc)
{
	if (dc->disp) {
		[dc->disp stopCaptureWithCompletionHandler:^(
				  NSError *_Nullable error) {
			blog(LOG_ERROR,
			     "destroy_general_stream: Failed to stop stream with error %s\n",
			     [[error localizedFailureReason]
				     cStringUsingEncoding:NSUTF8StringEncoding]);
			os_event_signal(dc->disp_finished);
		}];
		os_event_wait(dc->disp_finished);
	}

	if (dc->tex) {
		gs_texture_destroy(dc->tex);
		dc->tex = NULL;
	}

	if (dc->current) {
		IOSurfaceDecrementUseCount(dc->current);
		CFRelease(dc->current);
		dc->current = NULL;
	}

	if (dc->prev) {
		IOSurfaceDecrementUseCount(dc->prev);
		CFRelease(dc->prev);
		dc->prev = NULL;
	}

	if (dc->disp) {
		[dc->disp release];
		dc->disp = NULL;
	}

	os_event_destroy(dc->disp_finished);
	os_event_destroy(dc->stream_start_completed);
}

static void general_capture_destroy(void *data)
{
	struct general_capture *dc = data;

	if (!dc)
		return;

	obs_enter_graphics();

	destroy_general_stream(dc);

	if (dc->sampler)
		gs_samplerstate_destroy(dc->sampler);
	if (dc->vertbuf)
		gs_vertexbuffer_destroy(dc->vertbuf);

	obs_leave_graphics();

	if (dc->shareable_content) {
		os_sem_wait(dc->shareable_content_available);
		[dc->shareable_content release];
		os_sem_destroy(dc->shareable_content_available);
		dc->shareable_content_available = NULL;
	}

	if (dc->capture_delegate) {
		[dc->capture_delegate release];
	}

	destroy_window(&dc->window);

	pthread_mutex_destroy(&dc->mutex);
	bfree(dc);
}

static inline void general_stream_update(struct general_capture *dc,
					 CMSampleBufferRef sample_buffer)
{
	CVImageBufferRef image_buffer =
		CMSampleBufferGetImageBuffer(sample_buffer);

	CVPixelBufferLockBaseAddress(image_buffer, 0);
	size_t buffer_width = CVPixelBufferGetWidth(image_buffer);
	size_t buffer_height = CVPixelBufferGetHeight(image_buffer);
	IOSurfaceRef frame_surface = CVPixelBufferGetIOSurface(image_buffer);
	CVPixelBufferUnlockBaseAddress(image_buffer, 0);

	IOSurfaceRef prev_current = NULL;

	if (frame_surface && !pthread_mutex_lock(&dc->mutex)) {

		dc->frame.size.width = buffer_width;
		dc->frame.size.height = buffer_height;

		prev_current = dc->current;
		dc->current = frame_surface;
		CFRetain(dc->current);
		IOSurfaceIncrementUseCount(dc->current);

		pthread_mutex_unlock(&dc->mutex);
	}

	if (prev_current) {
		IOSurfaceDecrementUseCount(prev_current);
		CFRelease(prev_current);
	}
}

static bool init_general_stream(struct general_capture *dc)
{
	SCContentFilter *content_filter;

	os_sem_wait(dc->shareable_content_available);

	__block SCDisplay *target_display = nil;
	{
		[dc->shareable_content.displays
			indexOfObjectPassingTest:^BOOL(
				SCDisplay *_Nonnull display, NSUInteger idx,
				BOOL *_Nonnull stop) {
				if (display.displayID == dc->display) {
					target_display = dc->shareable_content
								 .displays[idx];
					*stop = TRUE;
				}
				return *stop;
			}];
	}

	__block SCWindow *target_window = nil;
	if (dc->window.window_id != 0) {
		[dc->shareable_content.windows indexOfObjectPassingTest:^BOOL(
						       SCWindow *_Nonnull window,
						       NSUInteger idx,
						       BOOL *_Nonnull stop) {
			if (window.windowID == dc->window.window_id) {
				target_window =
					dc->shareable_content.windows[idx];
				*stop = TRUE;
			}
			return *stop;
		}];
	}

	__block SCRunningApplication *target_application = nil;
	{
		[dc->shareable_content.applications
			indexOfObjectPassingTest:^BOOL(
				SCRunningApplication *_Nonnull application,
				NSUInteger idx, BOOL *_Nonnull stop) {
				if (application.bundleIdentifier ==
				    dc->application_id) {
					target_application =
						dc->shareable_content
							.applications[idx];
					*stop = TRUE;
				}
				return *stop;
			}];
	}
	NSArray *target_application_array =
		[[NSArray alloc] initWithObjects:target_application, nil];

	switch (dc->capture_type) {
	case GeneralCaptureDisplayStream: {
		content_filter = [[SCContentFilter alloc]
			 initWithDisplay:target_display
			excludingWindows:[[NSArray alloc] init]];
	} break;
	case GeneralCaptureWindowStream: {
		content_filter = [[SCContentFilter alloc]
			initWithDesktopIndependentWindow:target_window];
	} break;
	case GeneralCaptureApplicationStream: {
		content_filter = [[SCContentFilter alloc]
			      initWithDisplay:target_display
			includingApplications:target_application_array
			     exceptingWindows:[[NSArray alloc] init]];
	} break;
	}
	os_sem_post(dc->shareable_content_available);

	SCStreamConfiguration *stream_properties =
		[[SCStreamConfiguration alloc] init];
	[stream_properties setQueueDepth:5];
	[stream_properties setShowsCursor:!dc->hide_cursor];
	[stream_properties setPixelFormat:'BGRA'];

	dc->disp = [[SCStream alloc] initWithFilter:content_filter
				      configuration:stream_properties
					   delegate:nil];

	NSError *error = nil;
	BOOL did_add_output = [dc->disp addStreamOutput:dc->capture_delegate
						   type:SCStreamOutputTypeScreen
				     sampleHandlerQueue:nil
						  error:&error];
	if (!did_add_output) {
		blog(LOG_ERROR,
		     "init_general_stream: Failed to add stream output with error %s\n",
		     [[error localizedFailureReason]
			     cStringUsingEncoding:NSUTF8StringEncoding]);
		[error release];
		return !did_add_output;
	}

	os_event_init(&dc->disp_finished, OS_EVENT_TYPE_MANUAL);
	os_event_init(&dc->stream_start_completed, OS_EVENT_TYPE_MANUAL);

	__block BOOL did_stream_start = false;
	[dc->disp startCaptureWithCompletionHandler:^(
			  NSError *_Nullable error) {
		did_stream_start = (BOOL)(error == nil);
		if (!did_stream_start) {
			blog(LOG_ERROR,
			     "init_general_stream: Failed to add start capture with error %s\n",
			     [[error localizedFailureReason]
				     cStringUsingEncoding:NSUTF8StringEncoding]);
		}
		os_event_signal(dc->stream_start_completed);
	}];
	os_event_wait(dc->stream_start_completed);

	return did_stream_start;
}

bool init_vertbuf_general_capture(struct general_capture *dc)
{
	struct gs_vb_data *vb_data = gs_vbdata_create();
	vb_data->num = 4;
	vb_data->points = bzalloc(sizeof(struct vec3) * 4);
	if (!vb_data->points)
		return false;

	vb_data->num_tex = 1;
	vb_data->tvarray = bzalloc(sizeof(struct gs_tvertarray));
	if (!vb_data->tvarray)
		return false;

	vb_data->tvarray[0].width = 2;
	vb_data->tvarray[0].array = bzalloc(sizeof(struct vec2) * 4);
	if (!vb_data->tvarray[0].array)
		return false;

	dc->vertbuf = gs_vertexbuffer_create(vb_data, GS_DYNAMIC);
	return dc->vertbuf != NULL;
}

static void *general_capture_create(obs_data_t *settings, obs_source_t *source)
{
	struct general_capture *dc = bzalloc(sizeof(struct general_capture));

	dc->source = source;
	dc->hide_cursor = !obs_data_get_bool(settings, "show_cursor");

	init_window(&dc->window, settings);

	os_sem_init(&dc->shareable_content_available, 0);
	// ExcludingDesktopWindows set to true hides desktop elements like the wallpaper and cursor from the list
	// onScreenWindowsOnly set to true hides a number of invisible elements that OBS has no interest in, like focus proxies
	[SCShareableContent
		getShareableContentExcludingDesktopWindows:true
				       onScreenWindowsOnly:true
					 completionHandler:^(
						 SCShareableContent
							 *_Nullable shareable_content,
						 NSError *_Nullable error) {
						 if (error == nil &&
						     dc->shareable_content_available !=
							     NULL) {
							 dc->shareable_content =
								 [shareable_content
									 retain];
						 } else {
							 blog(LOG_ERROR,
							      "general_capture_create: Failed to get shareable content with error %s\n",
							      [[error localizedFailureReason]
								      cStringUsingEncoding:
									      NSUTF8StringEncoding]);
						 }
						 os_sem_post(
							 dc->shareable_content_available);
					 }];
	dc->capture_delegate = [[GeneralCaptureDelegate alloc] init];
	dc->capture_delegate.dc = dc;

	dc->effect = obs_get_base_effect(OBS_EFFECT_DEFAULT_RECT);
	if (!dc->effect)
		goto fail;

	obs_enter_graphics();

	struct gs_sampler_info info = {
		.filter = GS_FILTER_LINEAR,
		.address_u = GS_ADDRESS_CLAMP,
		.address_v = GS_ADDRESS_CLAMP,
		.address_w = GS_ADDRESS_CLAMP,
		.max_anisotropy = 1,
	};
	dc->sampler = gs_samplerstate_create(&info);
	if (!dc->sampler)
		goto fail;

	if (!init_vertbuf_general_capture(dc))
		goto fail;

	obs_leave_graphics();

	dc->capture_type = obs_data_get_int(settings, "type");
	dc->display = obs_data_get_int(settings, "display");
	dc->application_id = [[NSString alloc]
		initWithUTF8String:obs_data_get_string(settings,
						       "application")];
	pthread_mutex_init(&dc->mutex, NULL);

	if (!init_general_stream(dc))
		goto fail;

	return dc;

fail:
	obs_leave_graphics();
	general_capture_destroy(dc);
	return NULL;
}

static void build_sprite(struct gs_vb_data *data, float fcx, float fcy,
			 float start_u, float end_u, float start_v, float end_v)
{
	struct vec2 *tvarray = data->tvarray[0].array;

	vec3_set(data->points + 1, fcx, 0.0f, 0.0f);
	vec3_set(data->points + 2, 0.0f, fcy, 0.0f);
	vec3_set(data->points + 3, fcx, fcy, 0.0f);
	vec2_set(tvarray, start_u, start_v);
	vec2_set(tvarray + 1, end_u, start_v);
	vec2_set(tvarray + 2, start_u, end_v);
	vec2_set(tvarray + 3, end_u, end_v);
}

static inline void build_sprite_rect(struct gs_vb_data *data, float origin_x,
				     float origin_y, float end_x, float end_y)
{
	build_sprite(data, fabs(end_x - origin_x), fabs(end_y - origin_y),
		     origin_x, end_x, origin_y, end_y);
}

static void general_capture_video_tick(void *data, float seconds)
{
	UNUSED_PARAMETER(seconds);

	struct general_capture *dc = data;

	if (!dc->current)
		return;
	if (!obs_source_showing(dc->source))
		return;

	IOSurfaceRef prev_prev = dc->prev;
	if (pthread_mutex_lock(&dc->mutex))
		return;
	dc->prev = dc->current;
	dc->current = NULL;
	pthread_mutex_unlock(&dc->mutex);

	if (prev_prev == dc->prev)
		return;

	CGPoint origin = {0.f, 0.f};
	CGPoint end = {dc->frame.size.width, dc->frame.size.height};

	obs_enter_graphics();
	build_sprite_rect(gs_vertexbuffer_get_data(dc->vertbuf), origin.x,
			  origin.y, end.x, end.y);

	if (dc->tex)
		gs_texture_rebind_iosurface(dc->tex, dc->prev);
	else
		dc->tex = gs_texture_create_from_iosurface(dc->prev);
	obs_leave_graphics();

	if (prev_prev) {
		IOSurfaceDecrementUseCount(prev_prev);
		CFRelease(prev_prev);
	}
}

static void general_capture_video_render(void *data, gs_effect_t *effect)
{
	UNUSED_PARAMETER(effect);
	struct general_capture *dc = data;

	if (!dc->tex)
		return;

	const bool linear_srgb = gs_get_linear_srgb();

	const bool previous = gs_framebuffer_srgb_enabled();
	gs_enable_framebuffer_srgb(linear_srgb);

	gs_vertexbuffer_flush(dc->vertbuf);
	gs_load_vertexbuffer(dc->vertbuf);
	gs_load_indexbuffer(NULL);
	gs_load_samplerstate(dc->sampler, 0);
	gs_technique_t *tech = gs_effect_get_technique(dc->effect, "Draw");
	gs_eparam_t *param = gs_effect_get_param_by_name(dc->effect, "image");
	if (linear_srgb)
		gs_effect_set_texture_srgb(param, dc->tex);
	else
		gs_effect_set_texture(param, dc->tex);
	gs_technique_begin(tech);
	gs_technique_begin_pass(tech, 0);

	gs_draw(GS_TRISTRIP, 0, 4);

	gs_technique_end_pass(tech);
	gs_technique_end(tech);

	gs_enable_framebuffer_srgb(previous);
}

static const char *general_capture_getname(void *unused)
{
	UNUSED_PARAMETER(unused);
	return "General Capture";
}

static uint32_t general_capture_getwidth(void *data)
{
	struct general_capture *dc = data;

	return dc->frame.size.width;
}

static uint32_t general_capture_getheight(void *data)
{
	struct general_capture *dc = data;

	return dc->frame.size.height;
}

static void general_capture_defaults(obs_data_t *settings)
{
	CGDirectDisplayID initial_display = 0;
	{
		NSScreen *mainScreen = [NSScreen mainScreen];
		if (mainScreen) {
			NSNumber *screen_num =
				mainScreen.deviceDescription[@"NSScreenNumber"];
			if (screen_num) {
				initial_display =
					(CGDirectDisplayID)
						screen_num.pointerValue;
			}
		}
	}

	obs_data_set_default_int(settings, "type", 0);
	obs_data_set_default_int(settings, "display", initial_display);
	obs_data_set_default_obj(settings, "application", NULL);
	obs_data_set_default_bool(settings, "show_cursor", true);

	window_defaults(settings);
}

static void general_capture_update(void *data, obs_data_t *settings)
{
	struct general_capture *dc = data;

	CGWindowID old_window_id = dc->window.window_id;
	update_window(&dc->window, settings);

	unsigned capture_type = obs_data_get_int(settings, "type");
	CGDirectDisplayID display = obs_data_get_int(settings, "display");
	NSString *application_id = [[NSString alloc]
		initWithUTF8String:obs_data_get_string(settings,
						       "application")];
	bool show_cursor = obs_data_get_bool(settings, "show_cursor");

	if (capture_type == dc->capture_type) {
		switch (dc->capture_type) {
		case GeneralCaptureDisplayStream: {
			if (dc->display == display &&
			    dc->hide_cursor != show_cursor)
				return;
		} break;
		case GeneralCaptureWindowStream: {
			if (old_window_id == dc->window.window_id &&
			    dc->hide_cursor != show_cursor)
				return;
		} break;
		case GeneralCaptureApplicationStream: {
			if (dc->display == display &&
			    [application_id
				    isEqualToString:dc->application_id] &&
			    dc->hide_cursor != show_cursor)
				return;
		} break;
		}
	}

	obs_enter_graphics();

	destroy_general_stream(dc);
	dc->capture_type = capture_type;
	dc->display = display;
	dc->application_id = application_id;
	dc->hide_cursor = !show_cursor;
	init_general_stream(dc);

	obs_leave_graphics();
}

static obs_properties_t *general_capture_properties(void *data)
{
	struct general_capture *dc = data;

	os_sem_wait(dc->shareable_content_available);
	[dc->shareable_content release];
	[SCShareableContent
		getShareableContentExcludingDesktopWindows:true
				       onScreenWindowsOnly:true
					 completionHandler:^(
						 SCShareableContent
							 *_Nullable shareable_content,
						 NSError *_Nullable error) {
						 if (error == nil &&
						     dc->shareable_content_available !=
							     NULL) {
							 dc->shareable_content =
								 [shareable_content
									 retain];
						 } else {
							 blog(LOG_ERROR,
							      "general_capture_properties: Failed to get shareable content with error %s\n",
							      [[error localizedFailureReason]
								      cStringUsingEncoding:
									      NSUTF8StringEncoding]);
						 }
						 os_sem_post(
							 dc->shareable_content_available);
					 }];

	obs_properties_t *props = obs_properties_create();

	obs_property_t *capture_type = obs_properties_add_list(
		props, "type", obs_module_text("Method"), OBS_COMBO_TYPE_LIST,
		OBS_COMBO_FORMAT_INT);
	obs_property_list_add_int(capture_type,
				  obs_module_text("DisplayCapture"), 0);
	obs_property_list_add_int(capture_type,
				  obs_module_text("WindowCapture"), 1);
	obs_property_list_add_int(capture_type, "Application Capture", 2);

	os_sem_wait(dc->shareable_content_available);

	obs_property_t *display_list = obs_properties_add_list(
		props, "display", obs_module_text("DisplayCapture.Display"),
		OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_INT);

	[dc->shareable_content.displays
		enumerateObjectsUsingBlock:^(SCDisplay *_Nonnull display,
					     NSUInteger idx,
					     BOOL *_Nonnull stop) {
			UNUSED_PARAMETER(idx);
			UNUSED_PARAMETER(stop);

			NSUInteger screen_index = [NSScreen.screens
				indexOfObjectPassingTest:^BOOL(
					NSScreen *_Nonnull screen,
					NSUInteger index, BOOL *_Nonnull stop) {
					UNUSED_PARAMETER(index);
					NSNumber *screen_num =
						screen.deviceDescription
							[@"NSScreenNumber"];
					CGDirectDisplayID screen_display_id =
						(CGDirectDisplayID)
							screen_num.pointerValue;
					stop = (BOOL)(screen_display_id ==
						      display.displayID);
					return stop;
				}];
			NSScreen *screen =
				[NSScreen.screens objectAtIndex:screen_index];

			char dimension_buffer[4][12] = {};
			char name_buffer[256] = {};
			sprintf(dimension_buffer[0], "%u",
				(uint32_t)screen.frame.size.width);
			sprintf(dimension_buffer[1], "%u",
				(uint32_t)screen.frame.size.height);
			sprintf(dimension_buffer[2], "%d",
				(int32_t)screen.frame.origin.x);
			sprintf(dimension_buffer[3], "%d",
				(int32_t)screen.frame.origin.y);

			sprintf(name_buffer,
				"%.200s: %.12sx%.12s @ %.12s,%.12s",
				screen.localizedName.UTF8String,
				dimension_buffer[0], dimension_buffer[1],
				dimension_buffer[2], dimension_buffer[3]);

			obs_property_list_add_int(display_list, name_buffer,
						  display.displayID);
		}];

	add_window_properties(props);

	obs_property_t *application_list = obs_properties_add_list(
		props, "application", obs_module_text("Application"),
		OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_STRING);

	[dc->shareable_content.applications
		enumerateObjectsUsingBlock:^(
			SCRunningApplication *_Nonnull application,
			NSUInteger idx, BOOL *_Nonnull stop) {
			UNUSED_PARAMETER(idx);
			UNUSED_PARAMETER(stop);
			const char *name =
				[application.applicationName UTF8String];
			const char *bundle_id =
				[application.bundleIdentifier UTF8String];
			obs_property_list_add_string(application_list, name,
						     bundle_id);
		}];

	os_sem_post(dc->shareable_content_available);

	obs_properties_add_bool(props, "show_cursor",
				obs_module_text("DisplayCapture.ShowCursor"));

	return props;
}

struct obs_source_info general_capture_info = {
	.id = "general_capture",
	.type = OBS_SOURCE_TYPE_INPUT,
	.get_name = general_capture_getname,

	.create = general_capture_create,
	.destroy = general_capture_destroy,

	.output_flags = OBS_SOURCE_VIDEO | OBS_SOURCE_CUSTOM_DRAW |
			OBS_SOURCE_DO_NOT_DUPLICATE | OBS_SOURCE_SRGB,
	.video_tick = general_capture_video_tick,
	.video_render = general_capture_video_render,

	.get_width = general_capture_getwidth,
	.get_height = general_capture_getheight,

	.get_defaults = general_capture_defaults,
	.get_properties = general_capture_properties,
	.update = general_capture_update,
	.icon_type = OBS_ICON_TYPE_GAME_CAPTURE,
};

@implementation GeneralCaptureDelegate

- (void)stream:(SCStream *)stream
	didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
		       ofType:(SCStreamOutputType)type
{
	if (self.dc != NULL) {
		general_stream_update(self.dc, sampleBuffer);
	}
}

@end

// "-Wunguarded-availability-new"
#pragma clang diagnostic pop
#endif
