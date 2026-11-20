package com.example.build;

import com.android.build.api.instrumentation.AsmClassVisitorFactory;
import com.android.build.api.instrumentation.ClassContext;
import com.android.build.api.instrumentation.ClassData;
import com.android.build.api.instrumentation.InstrumentationParameters;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

/**
 * Keep the upstream inference library, but replace its usage-statistics factory
 * with the no-op logger supplied by that same fixed SDK. This applies to every
 * variant and to both existing hand and new face tasks. No image data, task
 * counters, app-version metadata, or logger events enter the proto logger.
 *
 * This is an app-owned build transform, not a copied or modified SDK binary.
 * MediaPipe remains licensed under Apache-2.0 (see assets/models/MEDIAPIPE_LICENSE.txt).
 */
public abstract class OfflineTasksStatsVisitorFactory
        implements AsmClassVisitorFactory<InstrumentationParameters.None> {
    private static final String FACTORY =
            "com.google.mediapipe.tasks.core.logging.TasksStatsLoggerFactory";
    private static final String INPUT =
            "(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)";
    private static final String RETURN =
            "Lcom/google/mediapipe/tasks/core/logging/TasksStatsLogger;";

    @Override public boolean isInstrumentable(ClassData data) {
        return FACTORY.equals(data.getClassName());
    }

    @Override public ClassVisitor createClassVisitor(ClassContext context, ClassVisitor next) {
        return new ClassVisitor(Opcodes.ASM9, next) {
            private boolean replaced;

            @Override public MethodVisitor visitMethod(
                    int access, String name, String descriptor, String signature, String[] exceptions) {
                MethodVisitor output = super.visitMethod(access, name, descriptor, signature, exceptions);
                if ("create".equals(name) && (INPUT + RETURN).equals(descriptor)) {
                    replaced = true;
                    output.visitCode();
                    output.visitVarInsn(Opcodes.ALOAD, 0);
                    output.visitVarInsn(Opcodes.ALOAD, 1);
                    output.visitVarInsn(Opcodes.ALOAD, 2);
                    output.visitMethodInsn(Opcodes.INVOKESTATIC,
                            "com/google/mediapipe/tasks/core/logging/TasksStatsDummyLogger",
                            "create", INPUT + "Lcom/google/mediapipe/tasks/core/logging/TasksStatsDummyLogger;",
                            false);
                    output.visitInsn(Opcodes.ARETURN);
                    output.visitMaxs(3, 3);
                    output.visitEnd();
                    // Suppress the original body, frames, and local-variable metadata.
                    return new MethodVisitor(Opcodes.ASM9) {};
                }
                return output;
            }

            @Override public void visitEnd() {
                if (!replaced) {
                    throw new IllegalStateException(
                            "MediaPipe statistics API changed; offline logger patch requires review.");
                }
                super.visitEnd();
            }
        };
    }
}
