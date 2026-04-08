package com.bnfnc.quest3;

import android.graphics.SurfaceTexture;
import android.opengl.GLES11Ext;
import android.opengl.GLES20;

import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;

/**
 * QuestExternalTexture – Godot Android Plugin (template)
 *
 * Engine.GetSingleton("QuestExternalTexture") üzerinden erişilir.
 * get_camera_texture() metodu Godot tarafına external texture temsilcisini döndürmelidir.
 */
public class QuestExternalTexture extends GodotPlugin {

    private int _glTextureId = -1;
    private long _godotTextureRid = 0;
    private SurfaceTexture _surfaceTexture;

    public QuestExternalTexture(Godot godot) {
        super(godot);
    }

    @Override
    public String getPluginName() {
        return "QuestExternalTexture";
    }

    /**
     * Godot C# tarafı: singleton.Call("get_camera_texture")
     *
     * Not: Burada döndürülen değerin Godot tarafında Texture2D olarak
     * kullanılabilmesi için plugin tarafında doğru Godot texture köprüsü
     * tamamlanmalıdır.
     */
    public long get_camera_texture() {
        if (_glTextureId == -1) {
            initExternalTexture();
        }
        return _godotTextureRid;
    }

    private void initExternalTexture() {
        int[] ids = new int[1];
        GLES20.glGenTextures(1, ids, 0);
        _glTextureId = ids[0];

        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, _glTextureId);
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);

        _surfaceTexture = new SurfaceTexture(_glTextureId);
        _surfaceTexture.setOnFrameAvailableListener(st -> st.updateTexImage());

        // TODO 1: SurfaceTexture'ı Quest kamera kaynağına bağla.
        // TODO 2: Godot RenderingServer tarafında external texture kaydı oluştur.
        // TODO 3: Oluşan RID/ID değerini _godotTextureRid alanına yaz.
    }
}
