#include "zenolights.h"
#include "viewport/zenovis.h"
#include "zenoapplication.h"
#include "zenomainwindow.h"
#include "zeno/utils/log.h"
#include <zeno/types/PrimitiveObject.h>
#include <zenoui/comctrl/zcombobox.h>
#include <zenovis/ObjectsManager.h>
#include <zeno/types/UserData.h>
#include <glm/glm.hpp>
#include <glm/gtc/matrix_transform.hpp>
#include <glm/gtc/type_ptr.hpp>
#include <glm/vec2.hpp>
#include <glm/vec3.hpp>

ZenoLights::ZenoLights(QWidget *parent) : QWidget(parent) {
    QVBoxLayout* pMainLayout = new QVBoxLayout;
    pMainLayout->setContentsMargins(QMargins(0, 0, 0, 0));
    setLayout(pMainLayout);
    setFocusPolicy(Qt::ClickFocus);

    QPalette palette = this->palette();
    palette.setBrush(QPalette::Window, QColor(37, 37, 38));
    setPalette(palette);
    setAutoFillBackground(true);

    setSizePolicy(QSizePolicy::Minimum, QSizePolicy::Expanding);

    QHBoxLayout* pTitleLayout = new QHBoxLayout;

    QLabel* pPrim = new QLabel(tr("Light: "));
    pPrim->setProperty("cssClass", "proppanel");
    pTitleLayout->addWidget(pPrim);

    pPrimName->setProperty("cssClass", "proppanel");
    pTitleLayout->addWidget(pPrimName);

    pMainLayout->addLayout(pTitleLayout);

    lights_view->setAlternatingRowColors(true);
    lights_view->setProperty("cssClass", "proppanel");
    lights_view->setModel(this->dataModel);
    pMainLayout->addWidget(lights_view);

    connect(lights_view, &QListView::pressed, this, [&](auto & index){
        std::string name = this->dataModel->light_names[index.row()];
        auto scene = Zenovis::GetInstance().getSession()->get_scene();
        std::shared_ptr<zeno::IObject> ptr = scene->objectsMan->lightObjects[name];

        if (auto prim_in = dynamic_cast<zeno::PrimitiveObject *>(ptr.get())){
            zeno::vec3f pos = ptr->userData().getLiterial<zeno::vec3f>("pos", zeno::vec3f(0.0f));
            zeno::vec3f scale = ptr->userData().getLiterial<zeno::vec3f>("scale", zeno::vec3f(0.0f));
            zeno::vec3f rotate = ptr->userData().getLiterial<zeno::vec3f>("rotate", zeno::vec3f(0.0f));
            zeno::vec3f clr;
            if (prim_in->verts.has_attr("clr")) {
                clr = prim_in->verts.attr<zeno::vec3f>("clr")[0];
            } else {
                clr = zeno::vec3f(30000.0f, 30000.0f, 30000.0f);
            }
            posXEdit->setText(QString::number(pos[0]));
            posYEdit->setText(QString::number(pos[1]));
            posZEdit->setText(QString::number(pos[2]));

            scaleXEdit->setText(QString::number(scale[0]));
            scaleYEdit->setText(QString::number(scale[1]));
            scaleZEdit->setText(QString::number(scale[2]));

            rotateXEdit->setText(QString::number(rotate[0]));
            rotateYEdit->setText(QString::number(rotate[1]));
            rotateZEdit->setText(QString::number(rotate[2]));

            colorXEdit->setText(QString::number(clr[0]));
            colorYEdit->setText(QString::number(clr[1]));
            colorZEdit->setText(QString::number(clr[2]));

            zenoApp->getMainWindow()->selected = nullptr;
            zenoApp->getMainWindow()->lightPanel = this;
        }else{
            zeno::log_info("connect item not found {}", name);
        }
    });

    {
        QHBoxLayout* pPosLayout = new QHBoxLayout();
        QLabel* posHeader = new QLabel("Position: ");
        posHeader->setProperty("cssClass", "proppanel");
        pPosLayout->addWidget(posHeader);
        QLabel* posX = new QLabel(" x: ");
        posX->setProperty("cssClass", "proppanel");
        pPosLayout->addWidget(posX);
        posXEdit->setProperty("cssClass", "proppanel");
        pPosLayout->addWidget(posXEdit);
        QLabel* posY = new QLabel(" y: ");
        posY->setProperty("cssClass", "proppanel");
        pPosLayout->addWidget(posY);
        posYEdit->setProperty("cssClass", "proppanel");
        pPosLayout->addWidget(posYEdit);
        QLabel* posZ = new QLabel(" z: ");
        posZ->setProperty("cssClass", "proppanel");
        pPosLayout->addWidget(posZ);
        posZEdit->setProperty("cssClass", "proppanel");
        pPosLayout->addWidget(posZEdit);
        pMainLayout->addLayout(pPosLayout);
    }

    {
        QHBoxLayout* pScaleLayout = new QHBoxLayout();
        QLabel* scaleHeader = new QLabel("ScaleSize: ");
        scaleHeader->setProperty("cssClass", "proppanel");
        pScaleLayout->addWidget(scaleHeader);
        QLabel* scaleX = new QLabel(" x: ");
        scaleX->setProperty("cssClass", "proppanel");
        pScaleLayout->addWidget(scaleX);
        scaleXEdit->setProperty("cssClass", "proppanel");
        pScaleLayout->addWidget(scaleXEdit);
        QLabel* scaleY = new QLabel(" y: ");
        scaleY->setProperty("cssClass", "proppanel");
        pScaleLayout->addWidget(scaleY);
        scaleYEdit->setProperty("cssClass", "proppanel");
        pScaleLayout->addWidget(scaleYEdit);
        QLabel* scaleZ = new QLabel(" z: ");
        scaleZ->setProperty("cssClass", "proppanel");
        pScaleLayout->addWidget(scaleZ);
        scaleZEdit->setProperty("cssClass", "proppanel");
        pScaleLayout->addWidget(scaleZEdit);
        pMainLayout->addLayout(pScaleLayout);
    }

    {
        QHBoxLayout* pRotateLayout = new QHBoxLayout();
        QLabel* rotateHeader = new QLabel("Rotate: ");
        rotateHeader->setProperty("cssClass", "proppanel");
        pRotateLayout->addWidget(rotateHeader);
        QLabel* rotateX = new QLabel(" x: ");
        rotateX->setProperty("cssClass", "proppanel");
        pRotateLayout->addWidget(rotateX);
        rotateXEdit->setProperty("cssClass", "proppanel");
        pRotateLayout->addWidget(rotateXEdit);
        QLabel* rotateY = new QLabel(" y: ");
        rotateY->setProperty("cssClass", "proppanel");
        pRotateLayout->addWidget(rotateY);
        rotateYEdit->setProperty("cssClass", "proppanel");
        pRotateLayout->addWidget(rotateYEdit);
        QLabel* rotateZ = new QLabel(" z: ");
        rotateZ->setProperty("cssClass", "proppanel");
        pRotateLayout->addWidget(rotateZ);
        rotateZEdit->setProperty("cssClass", "proppanel");
        pRotateLayout->addWidget(rotateZEdit);
        pMainLayout->addLayout(pRotateLayout);
    }

    {
        QHBoxLayout* pColorLayout = new QHBoxLayout();
        QLabel* colorHeader = new QLabel("Color: ");
        colorHeader->setProperty("cssClass", "proppanel");
        pColorLayout->addWidget(colorHeader);
        QLabel* colorX = new QLabel(" x: ");
        colorX->setProperty("cssClass", "proppanel");
        pColorLayout->addWidget(colorX);
        colorXEdit->setProperty("cssClass", "proppanel");
        pColorLayout->addWidget(colorXEdit);
        QLabel* colorY = new QLabel(" y: ");
        colorY->setProperty("cssClass", "proppanel");
        pColorLayout->addWidget(colorY);
        colorYEdit->setProperty("cssClass", "proppanel");
        pColorLayout->addWidget(colorYEdit);
        QLabel* colorZ = new QLabel(" z: ");
        colorZ->setProperty("cssClass", "proppanel");
        pColorLayout->addWidget(colorZ);
        colorZEdit->setProperty("cssClass", "proppanel");
        pColorLayout->addWidget(colorZEdit);
        pMainLayout->addLayout(pColorLayout);
    }

    {
        QHBoxLayout* pMouseSenLayout = new QHBoxLayout();
        QLabel* mouseSen = new QLabel("MouseSensitive: ");
        mouseSen->setProperty("cssClass", "proppanel");
        pMouseSenLayout->addWidget(mouseSen);
        QLabel* mouseSenValue = new QLabel(" v: ");
        mouseSenValue->setProperty("cssClass", "proppanel");
        pMouseSenLayout->addWidget(mouseSenValue);
        mouseSenEdit->setProperty("cssClass", "proppanel");
        pMouseSenLayout->addWidget(mouseSenEdit);

        pMainLayout->addLayout(pMouseSenLayout);
    }

    pStatusBar->setProperty("cssClass", "proppanel");
    pMainLayout->addWidget(pStatusBar);

    connect(posXEdit, &QLineEdit::textEdited, this, [&](){ modifyLightData(); });
    connect(posYEdit, &QLineEdit::textEdited, this, [&](){ modifyLightData(); });
    connect(posZEdit, &QLineEdit::textEdited, this, [&](){ modifyLightData(); });

    connect(rotateXEdit, &QLineEdit::textEdited, this, [&](){ modifyLightData(); });
    connect(rotateYEdit, &QLineEdit::textEdited, this, [&](){ modifyLightData(); });
    connect(rotateZEdit, &QLineEdit::textEdited, this, [&](){ modifyLightData(); });

    connect(scaleXEdit, &QLineEdit::textEdited, this, [&](){ modifyLightData(); });
    connect(scaleYEdit, &QLineEdit::textEdited, this, [&](){ modifyLightData(); });
    connect(scaleZEdit, &QLineEdit::textEdited, this, [&](){ modifyLightData(); });

    connect(colorXEdit, &QLineEdit::textEdited, this, [&](){ modifyLightData(); });
    connect(colorYEdit, &QLineEdit::textEdited, this, [&](){ modifyLightData(); });
    connect(colorZEdit, &QLineEdit::textEdited, this, [&](){ modifyLightData(); });

    connect(posXEdit, &QLineEdit::cursorPositionChanged, this, [&](){ zenoApp->getMainWindow()->selected = posXEdit; });
    connect(posYEdit, &QLineEdit::cursorPositionChanged, this, [&](){ zenoApp->getMainWindow()->selected = posYEdit; });
    connect(posZEdit, &QLineEdit::cursorPositionChanged, this, [&](){ zenoApp->getMainWindow()->selected = posZEdit; });

    connect(rotateXEdit, &QLineEdit::cursorPositionChanged, this, [&](){ zenoApp->getMainWindow()->selected = rotateXEdit; });
    connect(rotateYEdit, &QLineEdit::cursorPositionChanged, this, [&](){ zenoApp->getMainWindow()->selected = rotateYEdit; });
    connect(rotateZEdit, &QLineEdit::cursorPositionChanged, this, [&](){ zenoApp->getMainWindow()->selected = rotateZEdit; });

    connect(scaleXEdit, &QLineEdit::cursorPositionChanged, this, [&](){ zenoApp->getMainWindow()->selected = scaleXEdit; });
    connect(scaleYEdit, &QLineEdit::cursorPositionChanged, this, [&](){ zenoApp->getMainWindow()->selected = scaleYEdit; });
    connect(scaleZEdit, &QLineEdit::cursorPositionChanged, this, [&](){ zenoApp->getMainWindow()->selected = scaleZEdit; });

    connect(colorXEdit, &QLineEdit::cursorPositionChanged, this, [&](){ zenoApp->getMainWindow()->selected = colorXEdit; });
    connect(colorYEdit, &QLineEdit::cursorPositionChanged, this, [&](){ zenoApp->getMainWindow()->selected = colorYEdit; });
    connect(colorZEdit, &QLineEdit::cursorPositionChanged, this, [&](){ zenoApp->getMainWindow()->selected = colorZEdit; });

    connect(posXEdit, &QLineEdit::editingFinished, this, [&](){ zenoApp->getMainWindow()->selected = nullptr; });
    connect(posYEdit, &QLineEdit::editingFinished, this, [&](){ zenoApp->getMainWindow()->selected = nullptr; });
    connect(posZEdit, &QLineEdit::editingFinished, this, [&](){ zenoApp->getMainWindow()->selected = nullptr; });

    connect(rotateXEdit, &QLineEdit::editingFinished, this, [&](){ zenoApp->getMainWindow()->selected = nullptr; });
    connect(rotateYEdit, &QLineEdit::editingFinished, this, [&](){ zenoApp->getMainWindow()->selected = nullptr; });
    connect(rotateZEdit, &QLineEdit::editingFinished, this, [&](){ zenoApp->getMainWindow()->selected = nullptr; });

    connect(scaleXEdit, &QLineEdit::editingFinished, this, [&](){ zenoApp->getMainWindow()->selected = nullptr; });
    connect(scaleYEdit, &QLineEdit::editingFinished, this, [&](){ zenoApp->getMainWindow()->selected = nullptr; });
    connect(scaleZEdit, &QLineEdit::editingFinished, this, [&](){ zenoApp->getMainWindow()->selected = nullptr; });

    connect(colorXEdit, &QLineEdit::editingFinished, this, [&](){ zenoApp->getMainWindow()->selected = nullptr; });
    connect(colorYEdit, &QLineEdit::editingFinished, this, [&](){ zenoApp->getMainWindow()->selected = nullptr; });
    connect(colorZEdit, &QLineEdit::editingFinished, this, [&](){ zenoApp->getMainWindow()->selected = nullptr; });

    connect(mouseSenEdit, &QLineEdit::editingFinished, this, [&](){ zenoApp->getMainWindow()->mouseSen = mouseSenEdit->text().toFloat(); });
}

void ZenoLights::updateLights() {
    dataModel->updateByObjectsMan();
}

std::vector<zeno::vec3f> ZenoLights::computeLightPrim(zeno::vec3f position, zeno::vec3f rotate, zeno::vec3f scale){
    auto start_point = zeno::vec3f(0.5, 0, 0.5);
    float rm = 1.0f;
    float cm = 1.0f;
    std::vector<zeno::vec3f> verts;
    float ax = rotate[0] * (3.14159265358979323846 / 180.0);
    float ay = rotate[1] * (3.14159265358979323846 / 180.0);
    float az = rotate[2] * (3.14159265358979323846 / 180.0);
    glm::mat3 mx = glm::mat3(1, 0, 0, 0, cos(ax), -sin(ax), 0, sin(ax), cos(ax));
    glm::mat3 my = glm::mat3(cos(ay), 0, sin(ay), 0, 1, 0, -sin(ay), 0, cos(ay));
    glm::mat3 mz = glm::mat3(cos(az), -sin(az), 0, sin(az), cos(az), 0, 0, 0, 1);

    for(int i=0; i<=1; i++){
        auto rp = start_point - zeno::vec3f(i*rm, 0, 0);
        for(int j=0; j<=1; j++){
            auto p = rp - zeno::vec3f(0, 0, j*cm);
            // S R T
            p = p * scale;
            auto gp = glm::vec3(p[0], p[1], p[2]);
            gp = mz * my * mx * gp;
            p = zeno::vec3f(gp.x, gp.y, gp.z);
            auto zcp = zeno::vec3f(p[0], p[1], p[2]);
            zcp = zcp + position;

            verts.push_back(zcp);
        }
    }

    return verts;
}

void ZenoLights::modifyLightData() {
    auto index = this->lights_view->currentIndex();
    //printf("modifyLightData %d\n", index.row());
    if (index.row() == -1) {
        return;
    }
    float posX = posXEdit->text().toFloat();
    float posY = posYEdit->text().toFloat();
    float posZ = posZEdit->text().toFloat();
    float scaleX = scaleXEdit->text().toFloat();
    float scaleY = scaleYEdit->text().toFloat();
    float scaleZ = scaleZEdit->text().toFloat();
    float rotateX = rotateXEdit->text().toFloat();
    float rotateY = rotateYEdit->text().toFloat();
    float rotateZ = rotateZEdit->text().toFloat();

    float r = colorXEdit->text().toFloat();
    float g = colorYEdit->text().toFloat();
    float b = colorZEdit->text().toFloat();
    std::string name = this->dataModel->light_names[index.row()];

    zeno::vec3f pos = zeno::vec3f(posX, posY, posZ);
    zeno::vec3f scale = zeno::vec3f(scaleX, scaleY, scaleZ);
    zeno::vec3f rotate = zeno::vec3f(rotateX, rotateY, rotateZ);
    auto verts = computeLightPrim(pos, rotate, scale);

    auto scene = Zenovis::GetInstance().getSession()->get_scene();
    std::shared_ptr<zeno::IObject> obj = scene->objectsMan->lightObjects[name];
    auto prim_in = dynamic_cast<zeno::PrimitiveObject *>(obj.get());

    if(prim_in){
        auto &prim_verts = prim_in->verts;
        prim_verts[0] = verts[0];
        prim_verts[1] = verts[1];
        prim_verts[2] = verts[2];
        prim_verts[3] = verts[3];
        prim_in->verts.attr<zeno::vec3f>("clr")[0] = zeno::vec3f(r,g,b);

        prim_in->userData().setLiterial<zeno::vec3f>("pos", zeno::vec3f(posX, posY, posZ));
        prim_in->userData().setLiterial<zeno::vec3f>("scale", zeno::vec3f(scaleX, scaleY, scaleZ));
        prim_in->userData().setLiterial<zeno::vec3f>("rotate", zeno::vec3f(rotateX, rotateY, rotateZ));

        scene->objectsMan->needUpdateLight = true;
        zenoApp->getMainWindow()->updateViewport();
    }else{
        zeno::log_info("modifyLightData not found {}", name);
    }
}

