#include "simulator.h"
#include <SFML/Graphics.hpp>
#include "InertialEnergy.h"
#include "MassSpringEnergy.h"
#include "GravityEnergy.h"
#include "BarrierEnergy.h"
#include "FrictionEnergy.h"
#include "SpringEnergy.h"
#include <muda/muda.h>
#include <muda/container.h>
#include "uti.h"
using namespace muda;
template <typename T, int dim>
struct MovDirichletSimulator<T, dim>::Impl
{
    int n_seg;
    T h, rho, side_len, initial_stretch, m, tol, mu;
    int resolution = 900, scale = 200, offset = resolution / 2, radius = 5;
    std::vector<T> x, x_tilde, v, k, l2;
    std::vector<int> e;
    DeviceBuffer<int> device_DBC;
    DeviceBuffer<T> device_contact_area;
    sf::RenderWindow window;
    InertialEnergy<T, dim> inertialenergy;
    MassSpringEnergy<T, dim> massspringenergy;
    GravityEnergy<T, dim> gravityenergy;
    BarrierEnergy<T, dim> barrierenergy;
    FrictionEnergy<T, dim> frictionenergy;
    SpringEnergy<T, dim> springenergy;
    Impl(T rho, T side_len, T initial_stretch, T K, T h_, T tol_, T mu_, int n_seg);
    void update_x(const DeviceBuffer<T> &new_x);
    void update_x_tilde(const DeviceBuffer<T> &new_x_tilde);
    void update_v(const DeviceBuffer<T> &new_v);
    void update_DBC_target();
    T IP_val();
    void step_forward();
    void draw();
    DeviceBuffer<T> IP_grad();
    DeviceTripletMatrix<T, 1> IP_hess();
    DeviceBuffer<T> search_direction();
    T screen_projection_x(T point);
    T screen_projection_y(T point);
};
template <typename T, int dim>
MovDirichletSimulator<T, dim>::MovDirichletSimulator() = default;

template <typename T, int dim>
MovDirichletSimulator<T, dim>::~MovDirichletSimulator() = default;

template <typename T, int dim>
MovDirichletSimulator<T, dim>::MovDirichletSimulator(MovDirichletSimulator<T, dim> &&rhs) = default;

template <typename T, int dim>
MovDirichletSimulator<T, dim> &MovDirichletSimulator<T, dim>::operator=(MovDirichletSimulator<T, dim> &&rhs) = default;

template <typename T, int dim>
MovDirichletSimulator<T, dim>::MovDirichletSimulator(T rho, T side_len, T initial_stretch, T K, T h_, T tol_, T mu_, int n_seg) : pimpl_{std::make_unique<Impl>(rho, side_len, initial_stretch, K, h_, tol_, mu_, n_seg)}
{
}
template <typename T, int dim>
MovDirichletSimulator<T, dim>::Impl::Impl(T rho, T side_len, T initial_stretch, T K, T h_, T tol_, T mu_, int n_seg) : tol(tol_), h(h_), mu(mu_), window(sf::VideoMode(resolution, resolution), "MovDirichletSimulator")
{
    generate(side_len, n_seg, x, e);
    std::vector<int> DBC(x.size() / dim, 0);
    std::vector<T> contact_area(x.size() / dim, side_len / n_seg);
    std::vector<T> ground_n(dim);
    ground_n[0] = 0.1, ground_n[1] = 1;
    T n_norm = ground_n[0] * ground_n[0] + ground_n[1] * ground_n[1];
    n_norm = sqrt(n_norm);
    for (int i = 0; i < dim; i++)
        ground_n[i] /= n_norm;
    std::vector<T> ground_o(dim);
    ground_o[0] = 0, ground_o[1] = -1;
    v.resize(x.size(), 0);
    k.resize(e.size() / 2, K);
    l2.resize(e.size() / 2);
    for (int i = 0; i < e.size() / 2; i++)
    {
        T diff = 0;
        int idx1 = e[2 * i], idx2 = e[2 * i + 1];
        for (int d = 0; d < dim; d++)
        {
            diff += (x[idx1 * dim + d] - x[idx2 * dim + d]) * (x[idx1 * dim + d] - x[idx2 * dim + d]);
        }
        l2[i] = diff;
    }
    m = rho * side_len * side_len / ((n_seg + 1) * (n_seg + 1));
    // initial stretch
    int N = x.size() / dim;
    for (int i = 0; i < N; i++)
        x[i * dim + 0] *= initial_stretch;
    inertialenergy = InertialEnergy<T, dim>(N, m);
    massspringenergy = MassSpringEnergy<T, dim>(x, e, l2, k);
    gravityenergy = GravityEnergy<T, dim>(N, m);
    barrierenergy = BarrierEnergy<T, dim>(x, ground_n, ground_o, contact_area);
    frictionenergy = FrictionEnergy<T, dim>(v, h, ground_n);
    springenergy = SpringEnergy<T, dim>(x, std::vector<T>(N, m), DBC, std::vector<T>(N * dim, 0), std::vector<T>(N * dim, 0), 0, h);
    DeviceBuffer<T> x_device(x);
    update_x(x_device);
    device_DBC = DeviceBuffer<int>(DBC);
    device_contact_area = DeviceBuffer<T>(contact_area);
}
template <typename T, int dim>
void MovDirichletSimulator<T, dim>::run()
{
    assert(dim == 2);
    bool running = true;
    auto &window = pimpl_->window;
    int time_step = 0;
    while (running)
    {
        sf::Event event;
        while (window.pollEvent(event))
        {
            if (event.type == sf::Event::Closed)
                running = false;
        }

        pimpl_->draw(); // Draw the current state

        // Update the simulation state
        std::cout << "Time step " << time_step++ << "\n";
        pimpl_->step_forward();
    }

    window.close();
}

template <typename T, int dim>
void MovDirichletSimulator<T, dim>::Impl::step_forward()
{
    DeviceBuffer<T> x_tilde(x.size()); // Predictive position
    update_x_tilde(add_vector<T>(x, v, 1, h));
    frictionenergy.update_mu_lambda(barrierenergy.compute_mu_lambda(mu));
    DeviceBuffer<T> x_n = x; // Copy current positions to x_n
    update_v(add_vector<T>(x, x_n, 1 / h, -1 / h));
    int iter = 0;
    T E_last = IP_val();
    DeviceBuffer<T> p = search_direction();
    T residual = max_vector(p) / h;
    // std::cout << "Initial residual " << residual << "\n";
    while (residual > tol)
    {
        // Line search
        T alpha = barrierenergy.init_step_size(p);
        DeviceBuffer<T> x0 = x;
        update_x(add_vector<T>(x0, p, 1.0, alpha));
        update_v(add_vector<T>(x, x_n, 1 / h, -1 / h));
        while (IP_val() > E_last)
        {
            alpha /= 2;
            update_x(add_vector<T>(x0, p, 1.0, alpha));
            update_v(add_vector<T>(x, x_n, 1 / h, -1 / h));
        }
        std::cout << "step size = " << alpha << "\n";
        E_last = IP_val();
        std::cout << "Iteration " << iter << " residual " << residual << " E_last" << E_last << "\n";
        p = search_direction();
        residual = max_vector(p) / h;
        iter += 1;
    }
    update_v(add_vector<T>(x, x_n, 1 / h, -1 / h));
}
template <typename T, int dim>
T MovDirichletSimulator<T, dim>::Impl::screen_projection_x(T point)
{
    return offset + scale * point;
}
template <typename T, int dim>
T MovDirichletSimulator<T, dim>::Impl::screen_projection_y(T point)
{
    return resolution - (offset + scale * point);
}
template <typename T, int dim>
void MovDirichletSimulator<T, dim>::Impl::update_x(const DeviceBuffer<T> &new_x)
{
    inertialenergy.update_x(new_x);
    massspringenergy.update_x(new_x);
    gravityenergy.update_x(new_x);
    barrierenergy.update_x(new_x);
    new_x.copy_to(x);
}
template <typename T, int dim>
void MovDirichletSimulator<T, dim>::Impl::update_x_tilde(const DeviceBuffer<T> &new_x_tilde)
{
    inertialenergy.update_x_tilde(new_x_tilde);
    new_x_tilde.copy_to(x_tilde);
}
template <typename T, int dim>
void MovDirichletSimulator<T, dim>::Impl::update_v(const DeviceBuffer<T> &new_v)
{
    frictionenergy.update_v(new_v);
    new_v.copy_to(v);
}
template <typename T, int dim>
void MovDirichletSimulator<T, dim>::Impl::update_DBC_target()
{
    springenergy.update_DBC_target();
}
template <typename T, int dim>
void MovDirichletSimulator<T, dim>::Impl::draw()
{
    window.clear(sf::Color::White); // Clear the previous frame

    // Draw springs as lines
    for (int i = 0; i < e.size() / 2; ++i)
    {
        sf::Vertex line[] = {
            sf::Vertex(sf::Vector2f(screen_projection_x(x[e[i * 2] * dim]), screen_projection_y(x[e[i * 2] * dim + 1])), sf::Color::Blue),
            sf::Vertex(sf::Vector2f(screen_projection_x(x[e[i * 2 + 1] * dim]), screen_projection_y(x[e[i * 2 + 1] * dim + 1])), sf::Color::Blue)};
        window.draw(line, 2, sf::Lines);
    }

    // Draw masses as circles
    for (int i = 0; i < x.size() / dim; ++i)
    {
        sf::CircleShape circle(radius); // Set a fixed radius for each mass
        circle.setFillColor(sf::Color::Red);
        circle.setPosition(screen_projection_x(x[i * dim]) - radius, screen_projection_y(x[i * dim + 1]) - radius); // Center the circle on the mass
        window.draw(circle);
    }

    window.display(); // Display the rendered frame
}

template <typename T, int dim>
T MovDirichletSimulator<T, dim>::Impl::IP_val()
{

    return inertialenergy.val() + (massspringenergy.val() + gravityenergy.val() + barrierenergy.val() + frictionenergy.val()) * h * h;
}

template <typename T, int dim>
DeviceBuffer<T> MovDirichletSimulator<T, dim>::Impl::IP_grad()
{
    return add_vector<T>(add_vector<T>(add_vector<T>(add_vector<T>(inertialenergy.grad(), massspringenergy.grad(), 1.0, h * h), gravityenergy.grad(), 1.0, h * h), barrierenergy.grad(), 1.0, h * h), frictionenergy.grad(), 1.0, h * h);
}

template <typename T, int dim>
DeviceTripletMatrix<T, 1> MovDirichletSimulator<T, dim>::Impl::IP_hess()
{
    DeviceTripletMatrix<T, 1> inertial_hess = inertialenergy.hess();
    DeviceTripletMatrix<T, 1> massspring_hess = massspringenergy.hess();
    DeviceTripletMatrix<T, 1> hess = add_triplet<T>(inertial_hess, massspring_hess, 1.0, h * h);
    DeviceTripletMatrix<T, 1> barrier_hess = barrierenergy.hess();
    hess = add_triplet<T>(hess, barrier_hess, 1.0, h * h);
    DeviceTripletMatrix<T, 1> friction_hess = frictionenergy.hess();
    hess = add_triplet<T>(hess, friction_hess, 1.0, h * h);
    return hess;
}
template <typename T, int dim>
DeviceBuffer<T> MovDirichletSimulator<T, dim>::Impl::search_direction()
{
    DeviceBuffer<T> dir;
    dir.resize(x.size());
    DeviceBuffer<T> grad = IP_grad();
    DeviceTripletMatrix<T, 1> hess = IP_hess();
    search_dir<T, dim>(grad, hess, dir, device_DBC);
    return dir;
}

template class MovDirichletSimulator<float, 2>;
template class MovDirichletSimulator<double, 2>;
template class MovDirichletSimulator<float, 3>;
template class MovDirichletSimulator<double, 3>;