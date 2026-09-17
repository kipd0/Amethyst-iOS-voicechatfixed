# Prerequisite variables
SOURCEDIR := src
OUTPUTDIR := build

SOURCES := $(shell find $(SOURCEDIR) -type f -name '*.java')
CLASSES := $(SOURCES:$(SOURCEDIR)/%.java=$(OUTPUTDIR)/%.class)

TARGETS := $(shell find $(SOURCEDIR) -mindepth 1 -maxdepth 1 -type d)
TARGETS := $(TARGETS:$(SOURCEDIR)/%=$(OUTPUTDIR)/%.jar)
TARGETS := $(filter-out $(OUTPUTDIR)/lwjgl.jar,$(TARGETS))

# Add all jars to classpath and allow compiling with private API
JCFLAGS := -cp "$(subst $() $(),:,$(wildcard $(SOURCEDIR)/*/):$(wildcard libs/*/*.jar))" -XDignore.symbol.file

all: $(TARGETS) lwjgl_bundles

# Sometimes the CI produces empty class file resulting in broken jar, so we check and abort here
check_empty_classes:
	@set -e
	@echo "Checking for empty class files"
	$(eval EMPTY_CLASSES := $(shell find $(OUTPUTDIR) -name '*.class' -size 0))
	@if [ -n "$(EMPTY_CLASSES)" ]; then \
		echo "Error: found empty class files in $@: $(EMPTY_CLASSES)"; \
		exit 1; \
	fi

# Rules for building java class
$(CLASSES): $(OUTPUTDIR)/%.class: $(SOURCEDIR)/%.java
	@set -e
	$(eval TARGET=$(word 2, $(subst /, ,$@)))
	@mkdir -p $(OUTPUTDIR)/classes
	@mkdir -p $(dir $@)
	@echo "Compiling $<"
	@$(BOOTJDK)/javac $(JCFLAGS) -d $(OUTPUTDIR)/classes $<
	@cp $(@:$(OUTPUTDIR)/$(TARGET)/%.class=$(OUTPUTDIR)/classes/%*.class) $(dir $@)/

$(OUTPUTDIR)/launcher.jar: $(CLASSES) check_empty_classes
	@set -e
	@echo "Creating $@"
	@$(BOOTJDK)/jar -cf $@ -C $(basename $@) .

# Keep two LWJGL bundles:
# - lwjgllegacy/lwjgl.jar: Amethyst's original LWJGL bundle for 1.21.11 and older.
# - lwjgl41/lwjgl.jar: Minecraft 26.3 LWJGL/SDL bundle.
#
# Neither bundle is placed directly in app/libs, so PojavLauncher can select
# the correct one before Minecraft loads any LWJGL classes.
lwjgl_bundles: $(CLASSES) check_empty_classes libs/others/lwjgl41/lwjgl.jar
	@set -e
	@echo "Creating legacy LWJGL bundle"
	@rm -rf $(OUTPUTDIR)/lwjgl_lib
	@mkdir -p $(OUTPUTDIR)/lwjgl_lib
	@cd $(OUTPUTDIR)/lwjgl_lib && find ../../libs/lwjgl -name 'lwjgl*.jar' -exec $(BOOTJDK)/jar -xf {} \; && rm -rf META-INF
	@cp -R $(OUTPUTDIR)/lwjgl/* $(OUTPUTDIR)/lwjgl_lib/
	@rm -f $(OUTPUTDIR)/lwjgl_lib/com/mojang/blaze3d/platform/MacosUtil.class
	@rm -rf libs/others/lwjgllegacy
	@mkdir -p libs/others/lwjgllegacy
	@$(BOOTJDK)/jar -cf libs/others/lwjgllegacy/lwjgl.jar -C $(OUTPUTDIR)/lwjgl_lib .
	@echo "Updating Minecraft 26.3 LWJGL bundle"
	@test -f $(OUTPUTDIR)/lwjgl/com/mojang/blaze3d/platform/MacosUtil.class
	@cd $(OUTPUTDIR)/lwjgl && $(BOOTJDK)/jar -uf ../../libs/others/lwjgl41/lwjgl.jar com/mojang/blaze3d/platform/MacosUtil.class

$(OUTPUTDIR)/patchjna_agent.jar: $(CLASSES)
	@set -e
	@mv $(basename $@)/com/sun/jna/Platform.class $(basename $@)/com/sun/jna/Platform.class.patch
	@mkdir -p $(basename $@)/com/mojang/blaze3d/platform
	@test -f $(OUTPUTDIR)/lwjgl/com/mojang/blaze3d/platform/MacosUtil.class
	@cp $(OUTPUTDIR)/lwjgl/com/mojang/blaze3d/platform/MacosUtil.class \
		$(basename $@)/com/mojang/blaze3d/platform/MacosUtil.class.patch
	@echo "Creating $@"
	@$(BOOTJDK)/jar -cfm $@ $(SOURCEDIR)/patchjna_agent.txt -C $(basename $@) .

$(OUTPUTDIR)/patchsvc.jar: $(CLASSES)
	@set -e
	@mv $(basename $@)/de/maxhenkel/lame4j/Mp3Decoder.class $(basename $@)/de/maxhenkel/lame4j/Mp3Decoder.class.patch
	@mv $(basename $@)/de/maxhenkel/lame4j/Mp3Encoder.class $(basename $@)/de/maxhenkel/lame4j/Mp3Encoder.class.patch
	@mv $(basename $@)/de/maxhenkel/opus4j/OpusDecoder.class $(basename $@)/de/maxhenkel/opus4j/OpusDecoder.class.patch
	@mv $(basename $@)/de/maxhenkel/opus4j/OpusEncoder.class $(basename $@)/de/maxhenkel/opus4j/OpusEncoder.class.patch
	@mv $(basename $@)/de/maxhenkel/rnnoise4j/Denoiser.class $(basename $@)/de/maxhenkel/rnnoise4j/Denoiser.class.patch
	@mv $(basename $@)/de/maxhenkel/speex4j/AutomaticGainControl.class $(basename $@)/de/maxhenkel/speex4j/AutomaticGainControl.class.patch
	@rm -rf $(basename $@)/de/maxhenkel/*/*.class
	@echo "Creating $@"
	@$(BOOTJDK)/jar -cfm $@ $(SOURCEDIR)/patchsvc.txt -C $(basename $@) .

clean:
	rm -rf $(OUTPUTDIR)
	rm -rf libs/others/lwjgllegacy

.SUFFIXES: .java
.PHONY: all clean lwjgl_bundles
