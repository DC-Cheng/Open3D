//
// Created by Wei Dong on 2019-05-30.
//

#include <tinyobjloader/tiny_obj_loader.h>
#include "../ClassIO/ExtendedTriangleMeshIO.h"

namespace open3d {
namespace io {

bool ReadExtendedTriangleMeshFromOBJ(const std::string &filename,
                                     geometry::ExtendedTriangleMesh &mesh) {
    tinyobj::attrib_t attrib;
    std::vector<tinyobj::shape_t> shapes;
    std::vector<tinyobj::material_t> materials;

    auto base_dir = utility::filesystem::GetFileParentDirectory(filename);

    std::string warn;
    std::string err;
    bool ret = tinyobj::LoadObj(&attrib,
                                &shapes,
                                &materials,
                                &warn,
                                &err,
                                filename.c_str(),
                                base_dir.c_str());

    if (!warn.empty()) {
        utility::PrintWarning("tinyobjfile: %s.\n", warn.c_str());
    }
    if (!err.empty()) {
        utility::PrintError("tinyobjfile: %s.\n", err.c_str());
    }
    if (!ret) {
        return false;
    }

    // Loop over shapes (usually only one mesh)
    if (shapes.size() > 1) {
        utility::PrintWarning(
            "More than 1 shape existing, only loading the 1st one!\n");
    } else if (shapes.empty()) {
        utility::PrintError("No shape found!\n");
        return false;
    }

    auto &shape = shapes[0];

    // Loop over faces(polygon)
    mesh.vertices_.resize(shape.mesh.indices.size());
    mesh.vertex_uvs_.resize(shape.mesh.indices.size());
    mesh.vertex_normals_.resize(shape.mesh.indices.size());
    mesh.triangles_.resize(shape.mesh.num_face_vertices.size());

    size_t index_offset = 0;
    for (size_t f = 0; f < shape.mesh.num_face_vertices.size(); f++) {
        int fv = shape.mesh.num_face_vertices[f];
        if (fv != 3) {
            utility::PrintError("This is not a triangle mesh!\n");
            return false;
        }

        // Loop over vertices in the face.
        Eigen::Vector3i triangle;
        for (size_t v = 0; v < fv; v++) {
            tinyobj::index_t idx = shape.mesh.indices[index_offset + v];
            triangle[v] = idx.vertex_index;

            tinyobj::real_t vx = attrib.vertices[3 * idx.vertex_index + 0];
            tinyobj::real_t vy = attrib.vertices[3 * idx.vertex_index + 1];
            tinyobj::real_t vz = attrib.vertices[3 * idx.vertex_index + 2];
            mesh.vertices_[idx.vertex_index] = Eigen::Vector3d(vx, vy, vz);

            tinyobj::real_t nx = attrib.normals[3 * idx.normal_index + 0];
            tinyobj::real_t ny = attrib.normals[3 * idx.normal_index + 1];
            tinyobj::real_t nz = attrib.normals[3 * idx.normal_index + 2];
            mesh.vertex_normals_[idx.vertex_index] =
                Eigen::Vector3d(nx, ny, nz);

            tinyobj::real_t tx = attrib.texcoords[2 * idx.texcoord_index + 0];
            tinyobj::real_t ty = attrib.texcoords[2 * idx.texcoord_index + 1];
            mesh.vertex_uvs_[idx.vertex_index] = Eigen::Vector2d(tx, ty);
        }

        mesh.triangles_[f] = triangle;
        index_offset += fv;
    }

    mesh.LoadImageTextures({base_dir + "/" + materials[0].diffuse_texname});

    return true;
}
} // namespace io
} // namespace open3d